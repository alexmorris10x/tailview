import Darwin
import Foundation

final class VideoServer {
    var onViewerStatus: ((String) -> Void)?
    var onMicrophonePacket: (() -> Void)?
    var onMicrophoneLevel: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    var authenticateSaved: ((UUID, String) -> Bool)?
    var onPairingRequest: ((UUID, String, String) -> Bool)?
    var onPairingSuccess: ((UUID, String) -> Void)?

    private let lock = NSLock()
    private let sendQueue = DispatchQueue(label: "TailView.frameSend")
    private let code: String
    private let audioSink: AudioSink?
    private var listenerFD: Int32
    private var activeFD: Int32 = -1
    private var activePairedID: UUID?
    private var running = false
    private var pairingDeadline = 0.0
    private var sendPending = false
    private var latestFrame: Data?
    private var didReportMicrophone = false
    private var lastLevelReport = 0.0

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
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
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
        let client = activePairedID == id ? activeFD : -1
        lock.unlock()
        if client >= 0 { Darwin.shutdown(client, SHUT_RDWR) }
    }

    func stop() {
        lock.lock()
        guard running || listenerFD >= 0 else { lock.unlock(); return }
        running = false
        let listener = listenerFD
        let client = activeFD
        listenerFD = -1
        activeFD = -1
        activePairedID = nil
        sendPending = false
        latestFrame = nil
        lock.unlock()
        if client >= 0 {
            sendQueue.async { Darwin.shutdown(client, SHUT_RDWR); Darwin.close(client) }
        }
        if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
        audioSink?.clear()
        onViewerStatus?("Disconnected")
    }

    func publish(_ jpeg: Data) {
        guard !jpeg.isEmpty, jpeg.count <= 2_000_000 else { return }
        lock.lock()
        latestFrame = jpeg
        guard running, activeFD >= 0, !sendPending else { lock.unlock(); return }
        sendPending = true
        let fd = activeFD
        lock.unlock()
        sendQueue.async { [weak self] in
            guard let self else { return }
            let packet = Packet.encode(.jpeg, jpeg)
            let sent = Self.writeExactly(fd, packet)
            self.lock.lock()
            self.sendPending = false
            self.lock.unlock()
            if !sent { self.finish(fd) }
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let fd = listenerFD; let active = running; lock.unlock()
            guard active, fd >= 0 else { return }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else {
                lock.lock(); let stillRunning = running; lock.unlock()
                if stillRunning { onError?("Could not accept viewer: \(String(cString: strerror(errno)))") }
                return
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let line = Self.readLine(client, maximum: PairingRequest.maximumLineBytes),
                  let request = PairingRequest.parse(line) else {
                Darwin.close(client)
                continue
            }
            var pairedID: UUID?
            var acknowledgment = Data("OK\n".utf8)
            switch request {
            case .session(let suppliedCode):
                guard suppliedCode == code else { Darwin.close(client); continue }
            case .authenticate(let id, let token):
                guard authenticateSaved?(id, token) == true else { Darwin.close(client); continue }
                pairedID = id
            case .pair(let suppliedCode, let id, let token, let deviceName):
                guard suppliedCode == code, isPairingAvailable(),
                      onPairingRequest?(id, deviceName, token) == true else {
                    Darwin.close(client); continue
                }
                pairedID = id
                acknowledgment = Data("PAIRED\n".utf8)
                disablePairing()
                onPairingSuccess?(id, deviceName)
            }
            guard Self.writeExactly(client, acknowledgment) else { Darwin.close(client); continue }
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var sendTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            lock.lock()
            guard running else { lock.unlock(); Darwin.close(client); return }
            activeFD = client
            activePairedID = pairedID
            let frame = latestFrame
            lock.unlock()
            didReportMicrophone = false
            lastLevelReport = 0
            onViewerStatus?("Connected")
            if let frame { publish(frame) }
            receiveMicrophone(client)
            finish(client)
        }
    }

    private func receiveMicrophone(_ fd: Int32) {
        while let header = Self.readExactly(fd, 5) {
            guard header[0] == PacketKind.microphone.rawValue else { return }
            let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= 65_536, length.isMultiple(of: 2),
                  let payload = Self.readExactly(fd, Int(length)) else { return }
            if !didReportMicrophone {
                didReportMicrophone = true
                onMicrophonePacket?()
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelReport >= 0.2 {
                lastLevelReport = now
                onMicrophoneLevel?(Self.microphoneLevel(payload))
            }
            audioSink?.append(payload)
        }
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

    private func finish(_ fd: Int32) {
        lock.lock()
        guard activeFD == fd else { lock.unlock(); return }
        activeFD = -1
        activePairedID = nil
        sendPending = false
        lock.unlock()
        sendQueue.async { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        audioSink?.clear()
        onViewerStatus?("Disconnected")
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
