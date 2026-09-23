import Darwin
import Foundation

@main
struct TransportSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw TestError.message("Pass the Mac Tailscale IPv4 address") }
        let address = CommandLine.arguments[1]
        let code = UUID().uuidString.lowercased()
        let server = try VideoServer(address: address, code: code, audioSink: nil)
        let deviceID = UUID()
        let token = String(repeating: "ab", count: 32)
        let pair = PairingRequest.pair(code: code, id: deviceID, token: token, deviceName: "Test iPad")
        let saved = PairingRequest.authenticate(id: deviceID, token: token)
        let credentials = CredentialStore()
        server.authenticateSaved = { credentials.authenticate($0, token: $1) }
        server.onPairingRequest = { credentials.add($0, token: $2); return true }
        let connected = DispatchSemaphore(value: 0)
        server.onViewerStatus = { if $0 == "Connected" { connected.signal() } }
        server.start()
        defer { server.stop() }

        try expectRejected(address, line: UUID().uuidString.lowercased() + "\n", reason: "wrong session code")
        try expectRejected(address, line: pair.line, reason: "pairing without Mac consent")
        try expectRejected(address, line: saved.line, reason: "unknown saved device")

        let client = try connect(to: address)
        guard writeExactly(client, Data((code + "\n").utf8)),
              readExactly(client, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Correct session code was not acknowledged")
        }
        guard connected.wait(timeout: .now() + 5) == .success else {
            throw TestError.message("Viewer did not become active")
        }

        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        server.publish(jpeg)
        guard let header = readExactly(client, 5), header[0] == PacketKind.jpeg.rawValue,
              let frame = readExactly(client, 4), frame == jpeg else {
            throw TestError.message("Screen frame was not delivered")
        }
        let microphone = Data([0x01, 0x00, 0x02, 0x00])
        guard writeExactly(client, Packet.encode(.microphone, microphone)) else {
            throw TestError.message("Microphone packet was not sent")
        }
        Darwin.shutdown(client, SHUT_RDWR)
        Darwin.close(client)

        server.enablePairing()
        try expectAccepted(address, line: pair.line, acknowledgment: "PAIRED\n")
        try expectRejected(address, line: pair.line, reason: "pairing window reused")
        try expectAccepted(address, line: saved.line, acknowledgment: "OK\n")
        try expectRejected(address,
                           line: PairingRequest.authenticate(id: deviceID, token: String(repeating: "cd", count: 32)).line,
                           reason: "wrong saved token")
        credentials.revoke(deviceID)
        try expectRejected(address, line: saved.line, reason: "revoked device")
        print("Transport smoke passed: session code, pairing consent, saved reconnect, revocation, frame, microphone packet")
    }

    private static func expectAccepted(_ address: String, line: String, acknowledgment: String) throws {
        let client = try connect(to: address)
        defer { Darwin.close(client) }
        guard writeExactly(client, Data(line.utf8)),
              readExactly(client, acknowledgment.utf8.count) == Data(acknowledgment.utf8) else {
            throw TestError.message("Request was not accepted: \(line.prefix(5))")
        }
    }

    private static func expectRejected(_ address: String, line: String, reason: String) throws {
        let client = try connect(to: address)
        defer { Darwin.close(client) }
        guard writeExactly(client, Data(line.utf8)) else { throw TestError.message("Could not send \(reason)") }
        var byte: UInt8 = 0
        let result = Darwin.recv(client, &byte, 1, 0)
        guard result == 0 else { throw TestError.message("Accepted \(reason) or timed out (recv=\(result), errno=\(errno))") }
    }

    private static func connect(to address: String) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError.message("Socket failed") }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(47_820).bigEndian
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else {
            Darwin.close(fd); throw TestError.message("Invalid address")
        }
        let status = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { Darwin.close(fd); throw TestError.message("Connect failed") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
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

    private enum TestError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}

private final class CredentialStore {
    private let lock = NSLock()
    private var tokens = [UUID: String]()

    func add(_ id: UUID, token: String) {
        lock.lock(); defer { lock.unlock() }
        tokens[id] = token
    }

    func authenticate(_ id: UUID, token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tokens[id] == token
    }

    func revoke(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        tokens.removeValue(forKey: id)
    }
}
