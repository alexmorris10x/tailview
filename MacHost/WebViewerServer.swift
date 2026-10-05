import CryptoKit
import Darwin
import Foundation
import os

/// Serves the browser viewer on 127.0.0.1 for `tailscale serve` to publish
/// over tailnet HTTPS. Every request must carry the Tailscale identity
/// header for this Mac's owner, which `tailscale serve` sets and strips
/// from incoming requests, and the Host and Origin of the tailnet address.
/// A WebSocket is relayed byte for byte to VideoServer through a socket
/// pair, so a browser still signs in with a paired credential.
final class WebViewerServer {
    static let port: UInt16 = 47_821
    private static let log = Logger(subsystem: "com.10x.tailview.mac", category: "Browser")
    private static let maximumRequestBytes = 16_384
    private static let maximumClientFrameBytes = 1 << 20
    private static let maximumRelays = 2
    private static let maximumPendingRequests = 8

    /// The Tailscale login allowed to connect, such as `name@github`.
    let allowedLogin: String
    /// The tailnet authority browsers use, such as `mac.tailnet.ts.net:47821`.
    let authority: String
    /// This Mac's Tailscale IPv4 address, to tell the page it runs on this
    /// Mac, where playing Mac sound would feed back into the capture.
    let ownAddress: String
    var onStatus: ((String) -> Void)?

    private let page: Data
    private let attachViewer: (Int32) -> Bool
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false
    private var pendingRequests = 0
    private var relays = [UUID: (client: Int32, bridge: Int32)]()

    init(allowedLogin: String, authority: String, ownAddress: String, page: Data,
         attachViewer: @escaping (Int32) -> Bool) {
        self.allowedLogin = allowedLogin
        self.authority = authority
        self.ownAddress = ownAddress
        self.page = page
        self.attachViewer = attachViewer
    }

    deinit { stop() }

    func start() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw ServerError.bind(error)
        }
        lock.lock(); listenerFD = fd; running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        let listener = listenerFD
        listenerFD = -1
        running = false
        // A relay removes itself under the lock before closing, so these
        // descriptors are still its own here.
        for relay in relays.values {
            Darwin.shutdown(relay.client, SHUT_RDWR)
            Darwin.shutdown(relay.bridge, SHUT_RDWR)
        }
        relays.removeAll()
        lock.unlock()
        if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
    }

    var browserCount: Int {
        lock.lock(); defer { lock.unlock() }
        return relays.count
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let fd = listenerFD; lock.unlock()
            guard fd >= 0 else { return }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            let admitted = running && pendingRequests < Self.maximumPendingRequests
            if admitted { pendingRequests += 1 }
            lock.unlock()
            guard admitted else { Darwin.close(client); continue }
            Thread.detachNewThread { [weak self] in
                guard let self else { Darwin.close(client); return }
                let upgraded = self.handle(client)
                if !upgraded { Darwin.close(client) }
            }
        }
    }

    // MARK: HTTP

    /// Returns true when the connection became a relay that owns `fd`.
    private func handle(_ fd: Int32) -> Bool {
        var released = false
        func release() {
            guard !released else { return }
            released = true
            lock.lock(); pendingRequests -= 1; lock.unlock()
        }
        defer { release() }
        Self.setTimeouts(fd, receive: 5, send: 5)
        guard let request = Self.readRequest(fd) else { return false }
        // Tailscale serve sets this header for tailnet users and replaces any
        // value a client sent. Requests without it did not come through serve.
        let login = request.headers["tailscale-user-login"] ?? ""
        guard login == allowedLogin else {
            Self.log.notice("Refused browser request from \(login.isEmpty ? "no Tailscale identity" : login, privacy: .public)")
            respond(fd, status: "403 Forbidden",
                    text: "TailView only accepts \(allowedLogin) through its Tailscale HTTPS address.")
            return false
        }
        // A matching Host also defeats DNS rebinding from a local web page.
        guard request.headers["host"]?.lowercased() == authority else {
            respond(fd, status: "421 Misdirected Request", text: "Open TailView at https://\(authority)/")
            return false
        }
        guard request.method == "GET" else {
            respond(fd, status: "405 Method Not Allowed", text: "Only GET is supported.")
            return false
        }
        switch request.path {
        case "/":
            var body = page
            // Only a hint for an audio warning; a forged header is appended to,
            // not replaced, by tailscale serve.
            if request.headers["x-forwarded-for"] == ownAddress,
               let marker = body.range(of: Data(#"data-same-mac="0""#.utf8)) {
                body.replaceSubrange(marker, with: Data(#"data-same-mac="1""#.utf8))
            }
            respond(fd, status: "200 OK", contentType: "text/html; charset=utf-8", body: body)
            return false
        case "/ws":
            guard request.headers["upgrade"]?.lowercased() == "websocket",
                  request.headers["connection"]?.lowercased().contains("upgrade") == true,
                  request.headers["sec-websocket-version"] == "13",
                  let key = request.headers["sec-websocket-key"], !key.isEmpty else {
                respond(fd, status: "400 Bad Request", text: "Expected a WebSocket upgrade.")
                return false
            }
            // Cross-site pages can open WebSockets with the user's cookies, so
            // only the viewer page's own origin may connect.
            guard request.headers["origin"]?.lowercased() == "https://\(authority)" else {
                respond(fd, status: "403 Forbidden", text: "Cross-origin WebSocket refused.")
                return false
            }
            return upgrade(fd, key: key, release: release)
        default:
            respond(fd, status: "404 Not Found", text: "Not found.")
            return false
        }
    }

    private func respond(_ fd: Int32, status: String, contentType: String = "text/plain; charset=utf-8",
                         text: String) {
        respond(fd, status: status, contentType: contentType, body: Data(text.utf8))
    }

    private func respond(_ fd: Int32, status: String, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "Referrer-Policy: no-referrer\r\n" +
            "Permissions-Policy: microphone=(self), camera=(), geolocation=()\r\n" +
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; " +
            "img-src blob:; connect-src 'self' wss://\(authority); worker-src blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n" +
            "X-Frame-Options: DENY\r\n" +
            "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        _ = Self.writeExactly(fd, response)
        Darwin.shutdown(fd, SHUT_WR)
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private static func readRequest(_ fd: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let terminator = Data("\r\n\r\n".utf8)
        while data.range(of: terminator) == nil {
            guard data.count < maximumRequestBytes else { return nil }
            let received = Darwin.recv(fd, &buffer, min(buffer.count, maximumRequestBytes - data.count), 0)
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { return nil }
            data.append(buffer, count: received)
        }
        // A browser sends nothing after a GET head until the upgrade completes.
        guard let end = data.range(of: terminator), end.upperBound == data.count,
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A repeated identity or routing header is ambiguous; refuse it.
            guard headers[name] == nil else {
                if ["tailscale-user-login", "host", "origin"].contains(name) { return nil }
                headers[name]! += ", " + value
                continue
            }
            headers[name] = value
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return Request(method: String(requestLine[0]), path: path, headers: headers)
    }

    // MARK: WebSocket relay

    private func upgrade(_ fd: Int32, key: String, release: () -> Void) -> Bool {
        lock.lock()
        let hasRoom = running && relays.count < Self.maximumRelays
        lock.unlock()
        guard hasRoom else {
            respond(fd, status: "503 Service Unavailable", text: "Another browser is already connected.")
            return false
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            respond(fd, status: "500 Internal Server Error", text: "Could not open a viewer session.")
            return false
        }
        let bridge = pair[0]
        let viewerEnd = pair[1]
        for end in [bridge, viewerEnd] {
            var yes: Int32 = 1
            var size: Int32 = 512 * 1_024
            setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(end, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(end, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        guard Self.writeExactly(fd, Data(response.utf8)), attachViewer(viewerEnd) else {
            Darwin.close(bridge); Darwin.close(viewerEnd)
            return false
        }
        let id = UUID()
        lock.lock()
        guard running else {
            lock.unlock()
            Darwin.shutdown(bridge, SHUT_RDWR); Darwin.close(bridge)
            return false
        }
        relays[id] = (fd, bridge)
        let count = relays.count
        lock.unlock()
        release()
        onStatus?("\(count) browser\(count == 1 ? "" : "s") connected")
        // The viewer keeps the socket open indefinitely; keepalives notice a
        // vanished tailscale serve proxy, and writes give up after a stall.
        Self.setTimeouts(fd, receive: 0, send: 5)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout<Int32>.size))

        let writeLock = NSLock()
        let toBrowser = Thread { [weak self] in
            self?.relayToBrowser(from: bridge, to: fd, writeLock: writeLock)
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.shutdown(bridge, SHUT_RDWR)
        }
        toBrowser.start()
        relayFromBrowser(fd, to: bridge, writeLock: writeLock)
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.shutdown(bridge, SHUT_RDWR)
        // Close only after both directions stop using the descriptors.
        while !toBrowser.isFinished { usleep(10_000) }
        lock.lock()
        relays.removeValue(forKey: id)
        let remaining = relays.count
        lock.unlock()
        Darwin.close(bridge)
        Darwin.close(fd)
        onStatus?(remaining == 0 ? "No browser connected" : "\(remaining) browser\(remaining == 1 ? "" : "s") connected")
        return true
    }

    /// Bytes from VideoServer go out as binary messages. The browser parses
    /// packets across message boundaries, so chunks need not align.
    private func relayToBrowser(from bridge: Int32, to client: Int32, writeLock: NSLock) {
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while true {
            let received = Darwin.recv(bridge, &buffer, buffer.count, 0)
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { return }
            let frame = Self.frame(opcode: 0x2, payload: Data(buffer[0..<received]))
            writeLock.lock()
            let sent = Self.writeExactly(client, frame)
            writeLock.unlock()
            guard sent else { return }
        }
    }

    private func relayFromBrowser(_ client: Int32, to bridge: Int32, writeLock: NSLock) {
        while let header = Self.readExactly(client, 2) {
            let opcode = header[0] & 0x0F
            let masked = header[1] & 0x80 != 0
            var length = UInt64(header[1] & 0x7F)
            // RFC 6455 requires every client frame to be masked.
            guard masked, header[0] & 0x70 == 0 else { return }
            if length == 126 {
                guard let extended = Self.readExactly(client, 2) else { return }
                length = extended.reduce(0) { ($0 << 8) | UInt64($1) }
            } else if length == 127 {
                guard let extended = Self.readExactly(client, 8) else { return }
                length = extended.reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard length <= UInt64(Self.maximumClientFrameBytes),
                  let mask = Self.readExactly(client, 4),
                  var payload = Self.readExactly(client, Int(length)) else { return }
            for index in payload.indices { payload[index] ^= mask[mask.startIndex + (index - payload.startIndex) % 4] }
            switch opcode {
            case 0x0, 0x2:
                guard payload.isEmpty || Self.writeExactly(bridge, payload) else { return }
            case 0x8:
                writeLock.lock()
                _ = Self.writeExactly(client, Self.frame(opcode: 0x8, payload: Data([0x03, 0xE8])))
                writeLock.unlock()
                return
            case 0x9:
                guard length <= 125 else { return }
                writeLock.lock()
                let sent = Self.writeExactly(client, Self.frame(opcode: 0xA, payload: payload))
                writeLock.unlock()
                guard sent else { return }
            case 0xA:
                continue
            default:
                // Text frames and unknown opcodes are not part of the protocol.
                return
            }
        }
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        frame.append(payload)
        return frame
    }

    // MARK: Sockets

    private static func setTimeouts(_ fd: Int32, receive: Int, send: Int) {
        var receiveTimeout = timeval(tv_sec: receive, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: send, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        guard count > 0 else { return data }
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let received = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { return false }
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
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }

    private enum ServerError: LocalizedError {
        case socket, bind(Int32)
        var errorDescription: String? {
            switch self {
            case .socket: return "Could not create the browser socket"
            case .bind(let code): return "Could not listen for browsers on port \(WebViewerServer.port): \(String(cString: strerror(code)))"
            }
        }
    }
}
