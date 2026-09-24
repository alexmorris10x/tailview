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
        let delivered = ControlRecorder()
        let microphones = MicrophoneCounter()
        let microphoneLevels = MicrophoneCounter()
        server.authenticateSaved = { credentials.authenticate($0, token: $1) }
        server.isPreferredMicrophone = { $0 == deviceID }
        server.onPairingRequest = { credentials.add($0, token: $2); return true }
        server.authorizeTrustedControl = { true }
        server.onControlCommand = { delivered.append($0) }
        server.onMicrophonePacket = { microphones.increment() }
        server.onMicrophoneLevel = { _ in microphoneLevels.increment() }
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
        try expectState(client, allowed: false, phase: "session connect")
        let click = ControlCommand(kind: .leftClick, x: 0.25, y: 0.75)
        guard let clickData = click.encoded(), ControlCommand.decode(clickData) == click else {
            throw TestError.message("Valid control command did not round trip")
        }
        let modifiedClick = ControlCommand(kind: .leftClick, x: 0.25, y: 0.75,
                                           modifiers: [.command, .option])
        let modifiedKey = ControlCommand(kind: .text, text: "c", modifiers: [.command])
        guard let modifiedClickData = modifiedClick.encoded(),
              ControlCommand.decode(modifiedClickData) == modifiedClick,
              let modifiedKeyData = modifiedKey.encoded(),
              ControlCommand.decode(modifiedKeyData) == modifiedKey else {
            throw TestError.message("Modified control command did not round trip")
        }
        guard ControlCommand(kind: .leftClick, x: -0.01, y: 0.5).encoded() == nil,
              ControlCommand(kind: .scroll, amount: 100).encoded() == nil,
              ControlCommand(kind: .scroll, amount: 0, horizontalAmount: 0).encoded() == nil,
              ControlCommand(kind: .scroll, horizontalAmount: 21).encoded() == nil,
              ControlCommand(kind: .leftClick, x: 0.5, y: 0.5, horizontalAmount: 1).encoded() == nil,
              ControlCommand(kind: .text, text: "\u{0000}").encoded() == nil,
              ControlCommand(kind: .text, text: "a", modifiers: []).encoded() == nil,
              ControlCommand(kind: .text, text: "a", modifiers: [.command, .command]).encoded() == nil,
              ControlCommand.decode(Data(#"{"kind":"text","text":"a","modifiers":["superuser"]}"#.utf8)) == nil,
              ControlCommand.decode(Data("bad JSON".utf8)) == nil else {
            throw TestError.message("Invalid control command was accepted")
        }
        let diagonalScroll = ControlCommand(kind: .scroll, amount: 2, horizontalAmount: -3)
        guard let scrollData = diagonalScroll.encoded(),
              ControlCommand.decode(scrollData) == diagonalScroll else {
            throw TestError.message("Two-axis scroll command did not round trip")
        }
        server.setControlEnabled(true)
        try expectState(client, allowed: false, phase: "session enable attempt")
        let macAudio = Data(repeating: 0x5a, count: 3_840)
        server.publishAudio(macAudio)
        var ready = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&ready, 1, 100) == 0 else {
            throw TestError.message("Session-code viewer received trusted Mac audio")
        }
        guard writeExactly(client, Packet.encode(.control, clickData)) else {
            throw TestError.message("Session-only control packet could not be sent")
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard delivered.count == 0 else { throw TestError.message("Session-code viewer controlled the Mac") }

        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        server.publish(jpeg)
        guard let frame = readPacket(client), frame.kind == .jpeg, frame.payload == jpeg else {
            throw TestError.message("Screen frame was not delivered")
        }
        let microphone = Data([0x01, 0x00, 0x02, 0x00])
        guard writeExactly(client, Packet.encode(.microphoneRequest, Data([1]))),
              writeExactly(client, Packet.encode(.microphone, microphone)) else {
            throw TestError.message("Session microphone packets could not be sent")
        }
        Darwin.shutdown(client, SHUT_RDWR)
        Darwin.close(client)

        server.enablePairing()
        let pairedClient = try connect(to: address)
        guard writeExactly(pairedClient, Data(pair.line.utf8)),
              readExactly(pairedClient, 7) == Data("PAIRED\n".utf8) else {
            throw TestError.message("Pairing was not acknowledged")
        }
        try expectState(pairedClient, allowed: true, phase: "paired connect")
        try expectMicrophoneState(pairedClient, allowed: true, phase: "paired connect")
        server.publishAudio(macAudio)
        var receivedMacAudio = false
        for _ in 0..<4 {
            guard let packet = readPacket(pairedClient) else { break }
            if packet.kind == .jpeg { continue }
            receivedMacAudio = packet.kind == .macAudio && packet.payload == macAudio
            break
        }
        guard receivedMacAudio else { throw TestError.message("Trusted viewer did not receive Mac audio") }
        let parser = PacketParser()
        let wireAudio = Packet.encode(.macAudio, macAudio)
        var parsedAudio = Data()
        var parsedEarly = false
        try parser.append(Data(wireAudio.prefix(7))) { _, _ in parsedEarly = true }
        guard !parsedEarly else { throw TestError.message("Partial Mac audio packet parsed early") }
        try parser.append(Data(wireAudio.dropFirst(7))) { kind, payload in
            if kind == .macAudio { parsedAudio = payload }
        }
        guard parsedAudio == macAudio else { throw TestError.message("Mac audio parser failed") }
        guard writeExactly(pairedClient, Packet.encode(.control, clickData)) else {
            throw TestError.message("Paired control packet could not be sent")
        }
        guard delivered.waitForCount(1), delivered.count == 1 else {
            throw TestError.message("Trusted paired control did not reach the Mac automatically")
        }
        server.setControlEnabled(false)
        try expectState(pairedClient, allowed: false, phase: "paired disable")
        guard writeExactly(pairedClient, Packet.encode(.control, clickData)) else {
            throw TestError.message("Control revoke packet could not be sent")
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard delivered.count == 1 else { throw TestError.message("Control worked after Mac revoked it") }
        Darwin.shutdown(pairedClient, SHUT_RDWR)
        Darwin.close(pairedClient)
        try expectRejected(address, line: pair.line, reason: "pairing window reused")
        let savedClient = try connect(to: address)
        guard writeExactly(savedClient, Data(saved.line.utf8)),
              readExactly(savedClient, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Saved device could not reconnect")
        }
        try expectState(savedClient, allowed: true, phase: "saved reconnect")
        try expectMicrophoneState(savedClient, allowed: true, phase: "saved reconnect")
        guard writeExactly(savedClient, Packet.encode(.control, clickData)),
              delivered.waitForCount(2), delivered.count == 2 else {
            throw TestError.message("Saved device did not regain control automatically")
        }

        // Pair a second device without disconnecting the first. Both must
        // receive frames, while one device owns Mac sound and microphone.
        let phoneID = UUID()
        let phoneToken = String(repeating: "ef", count: 32)
        let phonePair = PairingRequest.pair(code: code, id: phoneID, token: phoneToken,
                                            deviceName: "Test iPhone")
        server.enablePairing()
        var phoneClient = try connect(to: address)
        guard writeExactly(phoneClient, Data(phonePair.line.utf8)),
              readExactly(phoneClient, 7) == Data("PAIRED\n".utf8),
              server.viewerCount == 2 else {
            throw TestError.message("Second paired viewer did not connect alongside first")
        }
        try expectState(phoneClient, allowed: true, phase: "second viewer")
        try expectMicrophoneState(phoneClient, allowed: false, phase: "second viewer")
        server.publish(jpeg)
        try expectPayload(savedClient, kind: .jpeg, payload: jpeg, phase: "first viewer frame")
        try expectPayload(phoneClient, kind: .jpeg, payload: jpeg, phase: "second viewer frame")
        server.publishAudio(macAudio)
        try expectPayload(savedClient, kind: .macAudio, payload: macAudio, phase: "first viewer sound")
        try expectNoAudio(phoneClient, phase: "inactive phone sound")
        guard writeExactly(phoneClient, Packet.encode(.control, clickData)),
              delivered.waitForCount(3), delivered.count == 3 else {
            throw TestError.message("Second paired viewer could not control Mac")
        }
        guard writeExactly(phoneClient, Packet.encode(.microphone, microphone)) else {
            throw TestError.message("Second viewer microphone packet could not be sent")
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard microphones.count == 0 else { throw TestError.message("Inactive viewer microphone reached Mac (count \(microphones.count))") }
        guard writeExactly(savedClient, Packet.encode(.microphone, microphone)),
              microphones.waitForCount(1) else {
            throw TestError.message("First viewer microphone did not reach Mac")
        }
        guard writeExactly(phoneClient, Packet.encode(.microphoneRequest, Data([1]))) else {
            throw TestError.message("Phone could not request microphone")
        }
        try expectMicrophoneState(phoneClient, allowed: true, phase: "phone microphone takeover")
        try expectMicrophoneState(savedClient, allowed: false, phase: "iPad microphone demotion")
        server.publishAudio(macAudio)
        try expectPayload(phoneClient, kind: .macAudio, payload: macAudio, phase: "phone sound after takeover")
        try expectNoAudio(savedClient, phase: "inactive iPad sound after takeover")
        guard writeExactly(phoneClient, Packet.encode(.microphone, microphone)),
              microphones.waitForCount(2) else {
            throw TestError.message("Phone microphone did not reach Mac after takeover")
        }
        guard writeExactly(savedClient, Packet.encode(.microphone, microphone)) else {
            throw TestError.message("Demoted iPad could not send microphone packet")
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard microphones.count == 2 else { throw TestError.message("Demoted iPad microphone reached Mac") }

        // A short phone disconnect falls back to the iPad, but reconnecting
        // the same trusted phone restores the user's explicit mic selection.
        Darwin.shutdown(phoneClient, SHUT_RDWR)
        Darwin.close(phoneClient)
        guard waitForViewerCount(server, 1) else {
            throw TestError.message("Phone did not disconnect before microphone reconnect")
        }
        try expectMicrophoneState(savedClient, allowed: true, phase: "iPad fallback during phone disconnect")
        let phoneSaved = PairingRequest.authenticate(id: phoneID, token: phoneToken)
        phoneClient = try connect(to: address)
        guard writeExactly(phoneClient, Data(phoneSaved.line.utf8)),
              readExactly(phoneClient, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Selected phone could not reconnect")
        }
        try expectState(phoneClient, allowed: true, phase: "selected phone reconnect")
        try expectMicrophoneState(phoneClient, allowed: true, phase: "selected phone microphone restored")
        try expectMicrophoneState(savedClient, allowed: false, phase: "iPad microphone demoted on phone return")
        guard writeExactly(savedClient, Packet.encode(.microphoneRequest, Data([1]))) else {
            throw TestError.message("iPad could not reclaim microphone")
        }
        try expectMicrophoneState(savedClient, allowed: true, phase: "iPad microphone reclaim")
        try expectMicrophoneState(phoneClient, allowed: false, phase: "phone microphone demotion")

        // Replacing an authenticated device must work even with both slots full.
        let replacement = try connect(to: address)
        guard writeExactly(replacement, Data(saved.line.utf8)),
              readExactly(replacement, 3) == Data("OK\n".utf8),
              server.viewerCount == 2 else {
            throw TestError.message("Saved iPad could not replace its stale connection")
        }
        try expectState(replacement, allowed: true, phase: "iPad replacement")
        try expectMicrophoneState(replacement, allowed: true, phase: "iPad microphone after replacement")
        var oldConnectionClosed = false
        for _ in 0..<8 {
            if readPacket(savedClient) == nil { oldConnectionClosed = true; break }
        }
        guard oldConnectionClosed else { throw TestError.message("Replaced iPad connection remained open") }
        try expectRejected(address, line: code + "\n", reason: "third simultaneous viewer")
        server.disconnectPairedDevice(deviceID)
        try expectMicrophoneState(phoneClient, allowed: true, phase: "microphone handoff")
        Thread.sleep(forTimeInterval: 0.3)
        let levelsBeforeHandoff = microphoneLevels.count
        guard server.viewerCount == 1,
              writeExactly(phoneClient, Packet.encode(.microphone, microphone)),
              microphoneLevels.waitForCount(levelsBeforeHandoff + 1) else {
            throw TestError.message("Microphone did not transfer to remaining viewer")
        }
        Darwin.shutdown(savedClient, SHUT_RDWR)
        Darwin.close(savedClient)
        Darwin.shutdown(replacement, SHUT_RDWR)
        Darwin.close(replacement)
        Darwin.shutdown(phoneClient, SHUT_RDWR)
        Darwin.close(phoneClient)
        guard waitForViewerCount(server, 0) else {
            throw TestError.message("Viewers did not disconnect before reconnect order test")
        }

        // A host restart can reconnect the phone first. The iPad must become
        // microphone owner once it joins, independent of socket arrival order.
        let phoneFirst = try connect(to: address)
        guard writeExactly(phoneFirst, Data(phoneSaved.line.utf8)),
              readExactly(phoneFirst, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Phone could not reconnect first")
        }
        try expectState(phoneFirst, allowed: true, phase: "phone-first reconnect")
        try expectMicrophoneState(phoneFirst, allowed: true, phase: "phone-first reconnect")
        let ipadSecond = try connect(to: address)
        guard writeExactly(ipadSecond, Data(saved.line.utf8)),
              readExactly(ipadSecond, 3) == Data("OK\n".utf8) else {
            throw TestError.message("iPad could not reconnect second")
        }
        try expectState(ipadSecond, allowed: true, phase: "iPad-second reconnect")
        try expectMicrophoneState(ipadSecond, allowed: true, phase: "iPad-second reconnect")
        try expectMicrophoneState(phoneFirst, allowed: false, phase: "iPad priority")
        guard writeExactly(phoneFirst, Packet.encode(.microphoneRequest, Data([1]))) else {
            throw TestError.message("Phone could not take audio before both viewers disconnect")
        }
        try expectMicrophoneState(phoneFirst, allowed: true, phase: "phone audio selection")
        try expectMicrophoneState(ipadSecond, allowed: false, phase: "iPad audio handoff")
        Darwin.shutdown(phoneFirst, SHUT_RDWR)
        Darwin.close(phoneFirst)
        Darwin.shutdown(ipadSecond, SHUT_RDWR)
        Darwin.close(ipadSecond)
        guard waitForViewerCount(server, 0) else {
            throw TestError.message("Reconnect order viewers did not disconnect")
        }
        let ipadAfterGap = try connect(to: address)
        guard writeExactly(ipadAfterGap, Data(saved.line.utf8)),
              readExactly(ipadAfterGap, 3) == Data("OK\n".utf8) else {
            throw TestError.message("iPad could not reconnect after both viewers left")
        }
        try expectState(ipadAfterGap, allowed: true, phase: "iPad after gap")
        try expectMicrophoneState(ipadAfterGap, allowed: true, phase: "iPad temporary audio fallback")
        let phoneAfterGap = try connect(to: address)
        guard writeExactly(phoneAfterGap, Data(phoneSaved.line.utf8)),
              readExactly(phoneAfterGap, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Selected phone could not reconnect after both viewers left")
        }
        try expectState(phoneAfterGap, allowed: true, phase: "phone after gap")
        try expectMicrophoneState(phoneAfterGap, allowed: true, phase: "phone audio restored after gap")
        try expectMicrophoneState(ipadAfterGap, allowed: false, phase: "iPad yields after gap")
        Darwin.shutdown(ipadAfterGap, SHUT_RDWR)
        Darwin.close(ipadAfterGap)
        Darwin.shutdown(phoneAfterGap, SHUT_RDWR)
        Darwin.close(phoneAfterGap)
        guard waitForViewerCount(server, 0) else {
            throw TestError.message("Final viewers did not disconnect")
        }
        try expectRejected(address,
                           line: PairingRequest.authenticate(id: deviceID, token: String(repeating: "cd", count: 32)).line,
                           reason: "wrong saved token")
        credentials.revoke(deviceID)
        try expectRejected(address, line: saved.line, reason: "revoked device")
        server.stop()
        if let unexpected = try? connect(to: address) {
            Darwin.close(unexpected)
            throw TestError.message("Stopped server still accepted a viewer")
        }
        print("Transport smoke passed: pairing consent, two simultaneous viewers, isolated frames, single audio owner, audio takeover and handoff across reconnects, trusted control, revocation, stopped listener, session access denial")
    }

    private static func expectState(_ fd: Int32, allowed: Bool, phase: String) throws {
        for _ in 0..<3 {
            guard let packet = readPacket(fd) else { break }
            if packet.kind == .jpeg { continue }
            if packet.kind == .controlState, packet.payload == Data([allowed ? 1 : 0]) { return }
            break
        }
        throw TestError.message("Incorrect remote-control state at \(phase)")
    }

    private static func expectMicrophoneState(_ fd: Int32, allowed: Bool, phase: String) throws {
        for _ in 0..<8 {
            guard let packet = readPacket(fd) else { break }
            if packet.kind == .microphoneState,
               packet.payload == Data([allowed ? 1 : 0]) { return }
            if packet.kind == .jpeg || packet.kind == .macAudio { continue }
            break
        }
        throw TestError.message("Incorrect microphone owner at \(phase)")
    }

    private static func expectPayload(_ fd: Int32, kind: PacketKind, payload: Data,
                                      phase: String) throws {
        for _ in 0..<8 {
            guard let packet = readPacket(fd) else { break }
            if packet.kind == kind, packet.payload == payload { return }
        }
        throw TestError.message("Missing \(phase)")
    }

    private static func expectNoAudio(_ fd: Int32, phase: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 25)
            guard ready >= 0 else { throw TestError.message("Could not poll \(phase)") }
            if ready == 0 { continue }
            guard let packet = readPacket(fd) else { throw TestError.message("Viewer disconnected at \(phase)") }
            if packet.kind == .macAudio { throw TestError.message("Inactive viewer received Mac sound at \(phase)") }
        }
    }

    private static func waitForViewerCount(_ server: VideoServer, _ wanted: Int) -> Bool {
        for _ in 0..<40 {
            if server.viewerCount == wanted { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func readPacket(_ fd: Int32) -> (kind: PacketKind, payload: Data)? {
        guard let header = readExactly(fd, 5), let kind = PacketKind(rawValue: header[0]) else { return nil }
        let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 2_000_000, let payload = readExactly(fd, Int(length)) else { return nil }
        return (kind, payload)
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

private final class ControlRecorder {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var commands = [ControlCommand]()

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return commands.count
    }

    func append(_ command: ControlCommand) {
        lock.lock(); commands.append(command); lock.unlock()
        signal.signal()
    }

    func waitForCount(_ wanted: Int) -> Bool {
        while count < wanted {
            if signal.wait(timeout: .now() + 2) != .success { return false }
        }
        return true
    }
}

private final class MicrophoneCounter {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var value = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock(); signal.signal() }
    func waitForCount(_ wanted: Int) -> Bool {
        while count < wanted {
            if signal.wait(timeout: .now() + 2) != .success { return false }
        }
        return true
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
