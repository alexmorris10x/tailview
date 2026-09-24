import Darwin
import Foundation

final class VideoServer {
    private final class ViewerConnection {
        let id = UUID()
        let fd: Int32
        let pairedID: UUID?
        let prefersMicrophone: Bool
        let sendQueue: DispatchQueue
        var controlEnabled: Bool
        var framePending = false
        var audioPending = 0
        var didReportMicrophone = false
        var lastLevelReport = 0.0

        init(fd: Int32, pairedID: UUID?, controlEnabled: Bool, prefersMicrophone: Bool) {
            self.fd = fd
            self.pairedID = pairedID
            self.controlEnabled = controlEnabled
            self.prefersMicrophone = prefersMicrophone
            sendQueue = DispatchQueue(label: "TailView.viewerSend.\(id.uuidString)")
        }
    }

    private static let maximumViewers = 2
    var onViewerStatus: ((String) -> Void)?
    var onMicrophonePacket: (() -> Void)?
    var onMicrophoneLevel: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    var authenticateSaved: ((UUID, String) -> Bool)?
    var isPreferredMicrophone: ((UUID) -> Bool)?
    var onPairingRequest: ((UUID, String, String) -> Bool)?
    var onPairingSuccess: ((UUID, String) -> Void)?
    var onControlCommand: ((ControlCommand) -> Void)?
    /// Called under the server lock only after a saved credential or a new pairing succeeds.
    /// The host enables its input injector here so the first control packet is safe to accept.
    var authorizeTrustedControl: (() -> Bool)?
    var onControlSessionEnded: (() -> Void)?

    private let lock = NSLock()
    private let code: String
    private let audioSink: AudioSink?
    private var listenerFD: Int32
    private var viewers = [UUID: ViewerConnection]()
    private var microphoneOwner: UUID?
    // Keep an explicit choice through reconnects for this sharing session.
    // stop() and device revocation clear it.
    private var manuallySelectedMicrophone: UUID?
    private var pendingHandshakes = 0
    private var running = false
    private var pairingDeadline = 0.0
    private var latestFrame: Data?

    init(address: String, code: String, audioSink: AudioSink?) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = UInt16(47_820).bigEndian
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            Darwin.close(fd)
            throw ServerError.invalidAddress
        }
        let bound = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw ServerError.bind(error)
        }
        listenerFD = fd
        self.code = code
        self.audioSink = audioSink
    }

    deinit { stop() }

    func start() {
        lock.lock(); running = true; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    func enablePairing(for seconds: TimeInterval = 300) {
        lock.lock(); pairingDeadline = ProcessInfo.processInfo.systemUptime + seconds; lock.unlock()
    }

    func disablePairing() {
        lock.lock(); pairingDeadline = 0; lock.unlock()
    }

    func disconnectPairedDevice(_ id: UUID) {
        lock.lock()
        if manuallySelectedMicrophone == id { manuallySelectedMicrophone = nil }
        let clients = viewers.values.filter { $0.pairedID == id }
        lock.unlock()
        for client in clients { finish(client) }
    }

    var hasPairedViewer: Bool {
        lock.lock(); defer { lock.unlock() }
        return running && viewers.values.contains { $0.pairedID != nil }
    }

    var viewerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return viewers.count
    }

    var isControlEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return viewers.values.contains { $0.controlEnabled }
    }

    func setControlEnabled(_ enabled: Bool) {
        lock.lock()
        let hadControl = viewers.values.contains { $0.controlEnabled }
        let clients = Array(viewers.values)
        for client in clients { client.controlEnabled = enabled && running && client.pairedID != nil }
        let hasControl = clients.contains { $0.controlEnabled }
        lock.unlock()
        if hadControl && !hasControl { onControlSessionEnded?() }
        for client in clients { sendControlState(client) }
    }

    func stop() {
        lock.lock()
        guard running || listenerFD >= 0 else { lock.unlock(); return }
        running = false
        let listener = listenerFD
        let clients = Array(viewers.values)
        let hadControl = clients.contains { $0.controlEnabled }
        listenerFD = -1
        viewers.removeAll()
        microphoneOwner = nil
        manuallySelectedMicrophone = nil
        latestFrame = nil
        lock.unlock()
        if hadControl { onControlSessionEnded?() }
        for client in clients { close(client) }
        if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
        audioSink?.clear()
        onViewerStatus?("Disconnected")
    }

    func publish(_ jpeg: Data) {
        guard !jpeg.isEmpty, jpeg.count <= 2_000_000 else { return }
        lock.lock()
        latestFrame = jpeg
        let clients = running ? viewers.values.filter { !$0.framePending && $0.audioPending < 6 } : []
        for client in clients { client.framePending = true }
        lock.unlock()
        let packet = Packet.encode(.jpeg, jpeg)
        for client in clients {
            client.sendQueue.async { [weak self, client] in
                guard let self else { return }
                let sent = self.sendIfCurrent(packet, to: client)
                self.lock.lock(); client.framePending = false; self.lock.unlock()
                if !sent { self.finish(client) }
            }
        }
    }

    /// Sends stereo 48 kHz signed 16-bit PCM only to the audio owner.
    /// A bounded queue prevents a slow viewer from accumulating seconds of stale sound.
    func publishAudio(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count <= 65_536, pcm.count.isMultiple(of: 4) else { return }
        lock.lock()
        let clients = running ? viewers.values.filter {
            $0.pairedID != nil && $0.id == microphoneOwner && $0.audioPending < 12
        } : []
        for client in clients { client.audioPending += 1 }
        lock.unlock()
        let packet = Packet.encode(.macAudio, pcm)
        for client in clients {
            client.sendQueue.async { [weak self, client] in
                guard let self else { return }
                let sent = self.sendIfCurrent(packet, to: client)
                self.lock.lock(); client.audioPending = max(0, client.audioPending - 1); self.lock.unlock()
                if !sent { self.finish(client) }
            }
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let fd = listenerFD; let active = running; lock.unlock()
            guard active, fd >= 0 else { return }
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else {
                lock.lock(); let stillRunning = running; lock.unlock()
                if stillRunning { onError?("Could not accept viewer: \(String(cString: strerror(errno)))") }
                return
            }
            var yes: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            let mayHandshake = running && pendingHandshakes < 4
            if mayHandshake { pendingHandshakes += 1 }
            lock.unlock()
            guard mayHandshake else { Darwin.close(clientFD); continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { Darwin.close(clientFD); return }
                self.handleViewer(clientFD)
                self.lock.lock(); self.pendingHandshakes -= 1; self.lock.unlock()
            }
        }
    }

    private func handleViewer(_ fd: Int32) {
        var admitted: ViewerConnection?
        defer { if admitted == nil { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) } }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = Self.readLine(fd, maximum: PairingRequest.maximumLineBytes),
              let request = PairingRequest.parse(line) else { return }
        var pairedID: UUID?
        var pairingName: String?
        var acknowledgment = Data("OK\n".utf8)
        switch request {
        case .session(let suppliedCode):
            guard suppliedCode == code else { return }
        case .authenticate(let id, let token):
            guard authenticateSaved?(id, token) == true else { return }
            pairedID = id
        case .pair(let suppliedCode, let id, let token, let deviceName):
            guard suppliedCode == code, isPairingAvailable(), hasViewerCapacity(),
                  onPairingRequest?(id, deviceName, token) == true else { return }
            pairedID = id
            pairingName = deviceName
            acknowledgment = Data("PAIRED\n".utf8)
            disablePairing()
        }
        let preferredMicrophone = pairedID.map { isPreferredMicrophone?($0) == true } ?? false
        lock.lock()
        let replacedViewer = pairedID.flatMap { id in viewers.values.first { $0.pairedID == id } }
        guard running, viewers.count < Self.maximumViewers || replacedViewer != nil else {
            lock.unlock(); return
        }
        let allowed = pairedID != nil && (authorizeTrustedControl?() == true)
        let viewer = ViewerConnection(fd: fd, pairedID: pairedID, controlEnabled: allowed,
                                      prefersMicrophone: preferredMicrophone)
        let previousMicrophone = microphoneOwner.flatMap { viewers[$0] }
        if let replacedViewer { viewers.removeValue(forKey: replacedViewer.id) }
        viewers[viewer.id] = viewer
        if let replacedViewer, previousMicrophone === replacedViewer {
            microphoneOwner = viewer.id
        } else if pairedID != nil && (previousMicrophone == nil ||
                                      manuallySelectedMicrophone == pairedID ||
                                      (manuallySelectedMicrophone == nil && preferredMicrophone &&
                                       previousMicrophone?.prefersMicrophone == false)) {
            microphoneOwner = viewer.id
        }
        let demotedMicrophone = previousMicrophone?.id == microphoneOwner ? nil : previousMicrophone
        let frame = latestFrame
        lock.unlock()
        admitted = viewer
        if let replacedViewer { close(replacedViewer) }
        guard Self.writeExactly(fd, acknowledgment) else { finish(viewer); return }
        if let demotedMicrophone {
            audioSink?.clear()
            sendMicrophoneState(demotedMicrophone)
        }
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        if let pairedID, let pairingName { onPairingSuccess?(pairedID, pairingName) }
        onViewerStatus?("Connected")
        sendControlState(viewer)
        sendMicrophoneState(viewer)
        if let frame { publish(frame) }
        receiveViewerPackets(viewer)
        finish(viewer)
    }

    private func receiveViewerPackets(_ viewer: ViewerConnection) {
        let fd = viewer.fd
        while let header = Self.readExactly(fd, 5) {
            let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard let kind = PacketKind(rawValue: header[0]) else { return }
            switch kind {
            case .microphone:
                guard length > 0, length <= 65_536, length.isMultiple(of: 2),
                      let payload = Self.readExactly(fd, Int(length)) else { return }
                lock.lock()
                let allowed = running && viewers[viewer.id] === viewer && microphoneOwner == viewer.id
                lock.unlock()
                guard allowed else { continue }
                if !viewer.didReportMicrophone {
                    viewer.didReportMicrophone = true
                    onMicrophonePacket?()
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - viewer.lastLevelReport >= 0.2 {
                    viewer.lastLevelReport = now
                    onMicrophoneLevel?(Self.microphoneLevel(payload))
                }
                audioSink?.append(payload)
            case .control:
                guard length > 0, length <= ControlCommand.maximumBytes,
                      let payload = Self.readExactly(fd, Int(length)),
                      let command = ControlCommand.decode(payload) else { return }
                lock.lock()
                let allowed = running && viewers[viewer.id] === viewer && viewer.controlEnabled
                lock.unlock()
                if allowed { onControlCommand?(command) }
            case .microphoneRequest:
                guard length == 1, let payload = Self.readExactly(fd, 1), payload == Data([1]) else { return }
                lock.lock()
                let allowed = running && viewers[viewer.id] === viewer && viewer.pairedID != nil
                let previous = microphoneOwner.flatMap { viewers[$0] }
                if allowed {
                    microphoneOwner = viewer.id
                    manuallySelectedMicrophone = viewer.pairedID
                }
                let changed = allowed && previous?.id != viewer.id
                lock.unlock()
                if changed {
                    audioSink?.clear()
                    if let previous { sendMicrophoneState(previous) }
                    sendMicrophoneState(viewer)
                }
            case .jpeg, .controlState, .macAudio, .microphoneState:
                return
            }
        }
    }

    private func sendControlState(_ viewer: ViewerConnection) {
        lock.lock(); let enabled = viewer.controlEnabled; lock.unlock()
        enqueue(Packet.encode(.controlState, Data([enabled ? 1 : 0])), to: viewer)
    }

    private func sendMicrophoneState(_ viewer: ViewerConnection) {
        guard viewer.pairedID != nil else { return }
        lock.lock(); let allowed = microphoneOwner == viewer.id; lock.unlock()
        enqueue(Packet.encode(.microphoneState, Data([allowed ? 1 : 0])), to: viewer)
    }

    private func enqueue(_ packet: Data, to viewer: ViewerConnection) {
        viewer.sendQueue.async { [weak self, viewer] in
            guard let self else { return }
            if !self.sendIfCurrent(packet, to: viewer) { self.finish(viewer) }
        }
    }

    private func sendIfCurrent(_ packet: Data, to viewer: ViewerConnection) -> Bool {
        lock.lock()
        let current = running && viewers[viewer.id] === viewer
        lock.unlock()
        return !current || Self.writeExactly(viewer.fd, packet)
    }

    private static func microphoneLevel(_ payload: Data) -> Double {
        payload.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard bytes.count >= 2 else { return 0 }
            var sum = 0.0
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits)) / 32768.0
                sum += sample * sample
            }
            return sqrt(sum / Double(bytes.count / 2))
        }
    }

    private func finish(_ viewer: ViewerConnection) {
        lock.lock()
        guard viewers[viewer.id] === viewer else { lock.unlock(); return }
        viewers.removeValue(forKey: viewer.id)
        let controlEnded = viewer.controlEnabled && !viewers.values.contains { $0.controlEnabled }
        let microphoneEnded = microphoneOwner == viewer.id
        var nextMicrophone: ViewerConnection?
        if microphoneEnded {
            nextMicrophone = viewers.values.first { $0.pairedID == manuallySelectedMicrophone && $0.pairedID != nil }
                ?? viewers.values.first { $0.pairedID != nil && $0.prefersMicrophone }
                ?? viewers.values.first { $0.pairedID != nil }
            microphoneOwner = nextMicrophone?.id
        }
        let connected = !viewers.isEmpty
        lock.unlock()
        close(viewer)
        if controlEnded { onControlSessionEnded?() }
        if microphoneEnded {
            audioSink?.clear()
            if let nextMicrophone { sendMicrophoneState(nextMicrophone) }
        }
        onViewerStatus?(connected ? "Connected" : "Disconnected")
    }

    private func close(_ viewer: ViewerConnection) {
        Darwin.shutdown(viewer.fd, SHUT_RDWR)
        viewer.sendQueue.async { Darwin.close(viewer.fd) }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let received = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if received <= 0 { return false }
                offset += received
            }
            return true
        }
        return success ? data : nil
    }

    private func isPairingAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pairingDeadline > ProcessInfo.processInfo.systemUptime
    }

    private func hasViewerCapacity() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && viewers.count < Self.maximumViewers
    }

    private static func readLine(_ fd: Int32, maximum: Int) -> String? {
        var data = Data()
        for _ in 0..<maximum {
            var byte: UInt8 = 0
            guard Darwin.recv(fd, &byte, 1, 0) == 1 else { return nil }
            if byte == 10 { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
        return nil
    }

    private static func writeExactly(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if sent <= 0 { return false }
                offset += sent
            }
            return true
        }
    }

    private enum ServerError: LocalizedError {
        case socket, invalidAddress, bind(Int32)
        var errorDescription: String? {
            switch self {
            case .socket: return "Could not create a network socket"
            case .invalidAddress: return "The Mac has no valid Tailscale IPv4 address"
            case .bind(let code): return "Could not listen on the Tailscale address: \(String(cString: strerror(code)))"
            }
        }
    }
}
