import Darwin
import Foundation

final class VideoServer {
    var onViewerStatus: ((String) -> Void)?
    var onMicrophonePacket: (() -> Void)?
    var onError: ((String) -> Void)?

    private let lock = NSLock()
    private let sendQueue = DispatchQueue(label: "TailView.frameSend")
    private let code: String
    private let audioSink: AudioSink?
    private var listenerFD: Int32
    private var activeFD: Int32 = -1
    private var running = false
    private var sendPending = false
    private var latestFrame: Data?
    private var didReportMicrophone = false

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

    func stop() {
        lock.lock()
        guard running || listenerFD >= 0 else { lock.unlock(); return }
        running = false
        let listener = listenerFD
        let client = activeFD
        listenerFD = -1
        activeFD = -1
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
            guard let auth = Self.readExactly(client, 37), String(data: auth, encoding: .utf8) == code + "\n",
                  Self.writeExactly(client, Data("OK\n".utf8)) else {
                Darwin.close(client)
                continue
            }
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var sendTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            lock.lock()
            guard running else { lock.unlock(); Darwin.close(client); return }
            activeFD = client
            let frame = latestFrame
            lock.unlock()
            didReportMicrophone = false
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
            audioSink?.append(payload)
        }
    }

    private func finish(_ fd: Int32) {
        lock.lock()
        guard activeFD == fd else { lock.unlock(); return }
        activeFD = -1
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
