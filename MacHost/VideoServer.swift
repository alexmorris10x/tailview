import Darwin
import Foundation
import os

final class VideoServer {
    private static let transportLog = Logger(subsystem: "com.10x.tailview.mac", category: "Transport")
    // Two seconds of stereo PCM, regardless of capture packet size.
    private static let maximumPendingAudioBytes = 48_000 * 4 * 2
    // Two frames in flight keep the link busy across the acknowledgment's
    // return trip while bounding how stale the viewer's screen can get.
    private static let maximumFrameCredits = 2
    // Viewers without flow control keep their former frame rate.
    private static let legacyFrameInterval = 0.125
    private struct LinkStats {
        var since = ProcessInfo.processInfo.systemUptime
        var frames = 0
        var frameBytes = 0
        var audioBytes = 0
        var roundTrips = 0
        var roundTripTotal = 0.0
        var roundTripMaximum = 0.0
    }
    private final class ViewerConnection {
        let id = UUID()
        let fd: Int32
        let pairedID: UUID?
        let prefersMicrophone: Bool
        let sendQueue: DispatchQueue
        var controlEnabled: Bool
        var framePending = false
        var audioPending = 0
        var audioPendingBytes = 0
        var didReportMicrophone = false
        var lastLevelReport = 0.0
        var functionHeld = false
        // Frame flow control starts with the viewer's first videoFlow packet.
        var flowControlled = false
        var frameCredits = 0
        // The viewer has not received the latest frame yet.
        var frameDirty = false
        var pumpScheduled = false
        var lastLegacyFrame = 0.0
        var unacknowledgedFrames = [Double]()
        var stats = LinkStats()
        // Both sides offered AAC; see AACAudio.
        var aacAudio = false
        // Used only by this viewer's reader thread.
        var microphoneDecoder: AACDecoder?

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
    var onLinkStats: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// Whether a saved credential is valid. `unavailable` means the list could
    /// not be read, so the device is not told it was revoked and retries.
    enum SavedCredentialCheck { case accepted, rejected, unavailable }
    var authenticateSaved: ((UUID, String) -> SavedCredentialCheck)?
    var isPreferredMicrophone: ((UUID) -> Bool)?
    var onPairingRequest: ((UUID, String, String) -> Bool)?
    var onPairingSuccess: ((UUID, String) -> Void)?
    var onControlCommand: ((ControlCommand) -> Void)?
    /// Clipboard text from a viewer with control, to paste; see ClipboardPaste.
    var onPaste: ((String) -> Void)?
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
    // Used only on the capture audio queue that calls publishAudio.
    private var macAudioEncoder: AACEncoder?
    private var macAudioEncoderOwner: UUID?

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
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        latestFrame = jpeg
        let clients = running ? viewers.values.filter { takeFrameSlot($0, now: now) } : []
        lock.unlock()
        guard !clients.isEmpty else { return }
        let packet = Packet.encode(.jpeg, jpeg)
        for client in clients { sendFrame(packet, to: client, queuedAt: now) }
    }

    /// Call with the lock held. Reserves a send for the latest frame, or marks
    /// that the viewer still needs it so a static screen is not left stale.
    private func takeFrameSlot(_ client: ViewerConnection, now: Double) -> Bool {
        // Audio has priority; the latest frame follows once audio drains.
        guard client.audioPending < 6 else { client.frameDirty = true; return false }
        if client.flowControlled {
            guard client.frameCredits > 0 else { client.frameDirty = true; return false }
            client.frameCredits -= 1
            client.unacknowledgedFrames.append(now)
        } else {
            guard !client.framePending else { client.frameDirty = true; return false }
            let wait = client.lastLegacyFrame + Self.legacyFrameInterval - now
            guard wait <= 0 else {
                client.frameDirty = true
                if !client.pumpScheduled {
                    client.pumpScheduled = true
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { [weak self, client] in
                        self?.lock.lock(); client.pumpScheduled = false; self?.lock.unlock()
                        self?.pumpLatestFrame(to: client)
                    }
                }
                return false
            }
            client.framePending = true
            client.lastLegacyFrame = now
        }
        client.frameDirty = false
        return true
    }

    private func pumpLatestFrame(to client: ViewerConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let frame = latestFrame
        let send = running && viewers[client.id] === client && client.frameDirty && frame != nil &&
            takeFrameSlot(client, now: now)
        lock.unlock()
        if send, let frame { sendFrame(Packet.encode(.jpeg, frame), to: client, queuedAt: now) }
    }

    private func sendFrame(_ packet: Data, to client: ViewerConnection, queuedAt: Double) {
        client.sendQueue.async { [weak self, client] in
            guard let self else { return }
            let sent = self.sendIfCurrent(packet, to: client)
            self.lock.lock()
            client.framePending = false
            client.stats.frames += 1
            client.stats.frameBytes += packet.count
            let pump = sent && client.frameDirty && !client.flowControlled
            self.lock.unlock()
            guard sent else { self.finish(client); return }
            if pump { self.pumpLatestFrame(to: client) }
            self.reportLinkStatsIfDue(client)
        }
    }

    private func handleVideoFlow(_ flow: VideoFlow, from client: ViewerConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        client.flowControlled = true
        switch flow {
        case .pause:
            client.frameCredits = 0
            client.unacknowledgedFrames.removeAll()
            client.frameDirty = true
        case .resume:
            client.frameCredits = Self.maximumFrameCredits
            client.unacknowledgedFrames.removeAll()
            client.frameDirty = true
        case .received:
            client.frameCredits = min(Self.maximumFrameCredits, client.frameCredits + 1)
            if !client.unacknowledgedFrames.isEmpty {
                let roundTrip = now - client.unacknowledgedFrames.removeFirst()
                client.stats.roundTrips += 1
                client.stats.roundTripTotal += roundTrip
                client.stats.roundTripMaximum = max(client.stats.roundTripMaximum, roundTrip)
            }
        }
        lock.unlock()
        pumpLatestFrame(to: client)
    }

    private func reportLinkStatsIfDue(_ client: ViewerConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let stats = client.stats
        let elapsed = now - stats.since
        guard elapsed >= 10 else { lock.unlock(); return }
        client.stats = LinkStats(since: now)
        let flowControlled = client.flowControlled
        lock.unlock()
        var summary = String(format: "%.1f fps · video %.0f KB/s · sound %.0f KB/s",
                             Double(stats.frames) / elapsed, Double(stats.frameBytes) / elapsed / 1000,
                             Double(stats.audioBytes) / elapsed / 1000)
        if flowControlled && stats.roundTrips > 0 {
            summary += String(format: " · frame round trip %.0f ms avg, %.0f ms max",
                              stats.roundTripTotal / Double(stats.roundTrips) * 1000,
                              stats.roundTripMaximum * 1000)
        } else if !flowControlled {
            summary += " · no frame acknowledgments"
        }
        Self.transportLog.notice("Viewer link: \(summary, privacy: .public)")
        onLinkStats?(summary)
    }

    /// Sends stereo 48 kHz signed 16-bit PCM, or AAC when the viewer offered
    /// it, only to the audio owner. A bounded queue prevents a slow viewer
    /// from accumulating seconds of stale sound.
    func publishAudio(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count <= 65_536, pcm.count.isMultiple(of: 4) else { return }
        lock.lock()
        let owner = running ? viewers.values.first { $0.pairedID != nil && $0.id == microphoneOwner } : nil
        let compressed = owner?.aacAudio == true
        lock.unlock()
        guard let owner else { return }
        guard compressed else {
            enqueueAudio(Packet.encode(.macAudio, pcm), duration: pcm.count, to: owner)
            return
        }
        // A new owner starts a new AAC stream.
        if macAudioEncoderOwner != owner.id {
            macAudioEncoder = AACEncoder(channels: 2, bitRate: 128_000)
            macAudioEncoderOwner = owner.id
        }
        for packet in macAudioEncoder?.encode(pcm) ?? [] {
            enqueueAudio(Packet.encode(.macAudioAAC, packet), duration: AACAudio.framesPerPacket * 4, to: owner)
        }
    }

    /// `duration` is the stereo PCM byte count the packet plays for, so the
    /// two-second budget is the same for PCM and AAC.
    private func enqueueAudio(_ packet: Data, duration: Int, to client: ViewerConnection) {
        lock.lock()
        let accepted = running && viewers[client.id] === client && client.id == microphoneOwner &&
            client.audioPendingBytes + duration <= Self.maximumPendingAudioBytes
        if accepted {
            client.audioPending += 1
            client.audioPendingBytes += duration
        }
        lock.unlock()
        guard accepted else { return }
        let queuedAt = ProcessInfo.processInfo.systemUptime
        client.sendQueue.async { [weak self, client] in
            guard let self else { return }
            let expired = ProcessInfo.processInfo.systemUptime - queuedAt > 2
            let sent = expired || self.sendIfAudioOwner(packet, to: client)
            self.lock.lock()
            client.audioPending = max(0, client.audioPending - 1)
            client.audioPendingBytes = max(0, client.audioPendingBytes - duration)
            if !expired { client.stats.audioBytes += packet.count }
            let pump = sent && client.frameDirty && client.audioPending < 6
            self.lock.unlock()
            if !sent { self.finish(client); return }
            if pump { self.pumpLatestFrame(to: client) }
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
            setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var idle: Int32 = 10
            var interval: Int32 = 3
            var probes: Int32 = 3
            setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &probes, socklen_t(MemoryLayout<Int32>.size))
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
        // shutdown wakes recv; close only after the reader and queued writers
        // have finished, so a reused descriptor cannot receive stale work.
        defer {
            if let admitted { admitted.sendQueue.async { Darwin.close(fd) } }
            else { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = Self.readLine(fd, maximum: PairingRequest.maximumLineBytes),
              let request = PairingRequest.parse(line) else { return }
        var pairedID: UUID?
        var pairingName: String?
        var acknowledgment = Data("OK\n".utf8)
        switch request {
        case .session(let suppliedCode):
            guard suppliedCode == code else { return }
        case .authenticate(let id, let token):
            switch authenticateSaved?(id, token) ?? .rejected {
            case .accepted: break
            case .rejected:
                // An explicit response distinguishes revocation from a dropped
                // handshake or a temporarily full/unavailable host.
                _ = Self.writeExactly(fd, Data("NO\n".utf8))
                return
            case .unavailable:
                // The device keeps its profile and retries.
                return
            }
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
        // Cellular RTT spikes and retransmissions can briefly fill the TCP
        // window. Frame/audio queues are already bounded, so allow a stalled
        // send to recover instead of resetting a healthy session at 250 ms.
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
                receiveMicrophone(payload, from: viewer)
            case .microphoneAAC:
                guard length > 0, length <= AACAudio.maximumPacketBytes,
                      let payload = Self.readExactly(fd, Int(length)) else { return }
                if viewer.microphoneDecoder == nil { viewer.microphoneDecoder = AACDecoder(channels: 1) }
                // A corrupt packet loses 21 ms of voice, not the session.
                if let pcm = viewer.microphoneDecoder?.decode(payload) { receiveMicrophone(pcm, from: viewer) }
            case .capabilities:
                guard length == 1, let payload = Self.readExactly(fd, 1) else { return }
                let aac = AACAudio.isAvailable && payload[0] & AACAudio.capability != 0
                lock.lock(); viewer.aacAudio = aac; lock.unlock()
                let capabilities = (AACAudio.isAvailable ? AACAudio.capability : 0) | ClipboardPaste.capability
                enqueue(Packet.encode(.capabilities, Data([capabilities])), to: viewer)
            case .control:
                guard length > 0, length <= ControlCommand.maximumBytes,
                      let payload = Self.readExactly(fd, Int(length)),
                      let command = ControlCommand.decode(payload) else { return }
                lock.lock()
                let allowed = running && viewers[viewer.id] === viewer && viewer.controlEnabled
                if allowed && command.kind == .functionDown { viewer.functionHeld = true }
                if command.kind == .functionUp { viewer.functionHeld = false }
                lock.unlock()
                if allowed { onControlCommand?(command) }
            case .paste:
                guard length > 0, length <= ClipboardPaste.maximumBytes,
                      let payload = Self.readExactly(fd, Int(length)),
                      let text = ClipboardPaste.decode(payload) else { return }
                lock.lock()
                let allowed = running && viewers[viewer.id] === viewer && viewer.controlEnabled
                lock.unlock()
                if allowed { onPaste?(text) }
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
            case .videoFlow:
                guard length == 1, let payload = Self.readExactly(fd, 1),
                      let flow = VideoFlow(rawValue: payload[0]) else { return }
                handleVideoFlow(flow, from: viewer)
            case .jpeg, .controlState, .macAudio, .microphoneState, .macAudioAAC:
                return
            }
        }
    }

    private func receiveMicrophone(_ pcm: Data, from viewer: ViewerConnection) {
        lock.lock()
        let allowed = running && viewers[viewer.id] === viewer && microphoneOwner == viewer.id
        lock.unlock()
        guard allowed else { return }
        if !viewer.didReportMicrophone {
            viewer.didReportMicrophone = true
            onMicrophonePacket?()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - viewer.lastLevelReport >= 0.2 {
            viewer.lastLevelReport = now
            onMicrophoneLevel?(Self.microphoneLevel(pcm))
        }
        audioSink?.append(pcm)
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

    private func sendIfAudioOwner(_ packet: Data, to viewer: ViewerConnection) -> Bool {
        lock.lock()
        let currentOwner = running && viewers[viewer.id] === viewer && microphoneOwner == viewer.id
        lock.unlock()
        return !currentOwner || Self.writeExactly(viewer.fd, packet)
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
        let releaseFunction = viewer.functionHeld && !controlEnded
        viewer.functionHeld = false
        lock.unlock()
        close(viewer)
        // Another device keeps control, so release only this device's Fn key.
        if releaseFunction { onControlCommand?(ControlCommand(kind: .functionUp)) }
        if controlEnded { onControlSessionEnded?() }
        if microphoneEnded {
            audioSink?.clear()
            if let nextMicrophone { sendMicrophoneState(nextMicrophone) }
        }
        onViewerStatus?(connected ? "Connected" : "Disconnected")
    }

    private func close(_ viewer: ViewerConnection) {
        Darwin.shutdown(viewer.fd, SHUT_RDWR)
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let received = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                if received <= 0 {
                    #if DEBUG
                    transportLog.notice("TCP receive ended result=\(received) errno=\(received < 0 ? errno : 0) offset=\(offset) count=\(count)")
                    #endif
                    return false
                }
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
                if sent < 0 && errno == EINTR { continue }
                if sent <= 0 {
                    #if DEBUG
                    transportLog.error("TCP send failed result=\(sent) errno=\(sent < 0 ? errno : 0) offset=\(offset) count=\(bytes.count)")
                    #endif
                    return false
                }
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
