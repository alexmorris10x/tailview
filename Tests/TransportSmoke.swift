import Darwin
import Foundation

@main
struct TransportSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw TestError.message("Pass the Mac Tailscale IPv4 address") }
        let address = CommandLine.arguments[1]
        var code = UUID().uuidString.lowercased()
        let server = try VideoServer(address: address, audioSink: nil)
        let deviceID = UUID()
        let token = String(repeating: "ab", count: 32)
        var pair = PairingRequest.pair(code: code, id: deviceID, token: token, deviceName: "Test iPad")
        let saved = PairingRequest.authenticate(id: deviceID, token: token)
        let credentials = CredentialStore()
        let delivered = ControlRecorder()
        let microphones = MicrophoneCounter()
        let microphoneLevels = MicrophoneCounter()
        server.authenticateSaved = { credentials.authenticate($0, token: $1) }
        server.isPreferredMicrophone = { $0 == deviceID }
        server.onPairingRequest = { credentials.add($0, token: $2); return true }
        let consent = HostTestConsent()
        server.authorizeTrustedControl = { consent.controlAllowed }
        let microphoneSink = HostTestMicrophoneSink()
        server.onControlCommand = { delivered.append($0) }
        let pastes = PasteRecorder()
        server.onPaste = { pastes.append($0) }
        server.onMicrophonePacket = { microphones.increment() }
        server.onMicrophoneLevel = { _ in microphoneLevels.increment() }
        let connected = DispatchSemaphore(value: 0)
        server.onViewerStatus = { if $0 == "Connected" { connected.signal() } }
        server.start()
        defer { server.stop() }

        try expectRejected(address, line: UUID().uuidString.lowercased() + "\n", reason: "wrong session code")
        try expectRejected(address, line: pair.line, reason: "pairing without Mac consent")
        try expectRejected(address, line: saved.line, reason: "unknown saved device")

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
              ControlCommand(kind: .window).encoded() == nil,
              ControlCommand(kind: .window, modifiers: [.control], window: .leftHalf).encoded() == nil,
              ControlCommand(kind: .key, key: .left, window: .fill).encoded() == nil,
              ControlCommand.decode(Data(#"{"kind":"window","window":"minimize"}"#.utf8)) == nil,
              ControlCommand.decode(Data("bad JSON".utf8)) == nil else {
            throw TestError.message("Invalid control command was accepted")
        }
        for layout in ControlCommand.WindowLayout.allCases {
            let command = ControlCommand(kind: .window, window: layout)
            guard let data = command.encoded(), ControlCommand.decode(data) == command else {
                throw TestError.message("Window command did not round trip")
            }
        }
        let diagonalScroll = ControlCommand(kind: .scroll, amount: 2, horizontalAmount: -3)
        guard let scrollData = diagonalScroll.encoded(),
              ControlCommand.decode(scrollData) == diagonalScroll else {
            throw TestError.message("Two-axis scroll command did not round trip")
        }
        let maximumPaste = String(repeating: "a", count: ClipboardPaste.maximumBytes)
        guard ClipboardPaste.encode("") == nil, ClipboardPaste.encode(maximumPaste + "a") == nil,
              ClipboardPaste.encode(maximumPaste) != nil, ClipboardPaste.decode(Data([0xff, 0xfe])) == nil,
              ClipboardPaste.decode(Data("é".utf8)) == "é" else {
            throw TestError.message("Paste size or encoding limits were not enforced")
        }

        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let microphone = Data([0x01, 0x00, 0x02, 0x00])
        let macAudio = Data(repeating: 0x5a, count: 3_840)
        let closedCode = server.enablePairing()
        server.disablePairing()
        try expectRejected(address, line: closedCode + "\n", reason: "closed legacy UUID")
        try expectRejected(address,
                           line: PairingRequest.pair(code: closedCode, id: deviceID, token: token, deviceName: "Test iPad").line,
                           reason: "closed pairing code")
        let expiredCode = server.enablePairing(for: -1)
        try expectRejected(address,
                           line: PairingRequest.pair(code: expiredCode, id: deviceID, token: token, deviceName: "Test iPad").line,
                           reason: "expired pairing window")
        code = server.enablePairing()
        guard code != closedCode, code != expiredCode else { throw TestError.message("Pairing codes were reused") }
        try expectRejected(address, line: code + "\n", reason: "legacy UUID during open pairing")
        try expectRejected(address,
                           line: PairingRequest.pair(code: closedCode, id: deviceID, token: token, deviceName: "Test iPad").line,
                           reason: "old code during a new pairing window")
        pair = PairingRequest.pair(code: code, id: deviceID, token: token, deviceName: "Test iPad")
        let pairedClient = try connect(to: address)
        guard writeExactly(pairedClient, Data(pair.line.utf8)),
              readExactly(pairedClient, 7) == Data("PAIRED\n".utf8) else {
            throw TestError.message("Pairing was not acknowledged")
        }
        try expectState(pairedClient, allowed: false, phase: "paired without control consent")
        try expectMicrophoneState(pairedClient, allowed: true, phase: "paired connect")
        guard writeExactly(pairedClient, Packet.encode(.control, clickData)),
              let noConsentPaste = ClipboardPaste.encode("without consent"),
              writeExactly(pairedClient, Packet.encode(.paste, noConsentPaste)),
              writeExactly(pairedClient, Packet.encode(.microphone, microphone)) else {
            throw TestError.message("Could not exercise the host consent gates")
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard delivered.count == 0, pastes.texts.isEmpty, microphones.count == 0 else {
            throw TestError.message("Pairing implicitly enabled control or microphone routing")
        }
        // Screen and Mac sound remain available without control or microphone consent.
        server.publish(jpeg)
        try expectPayload(pairedClient, kind: .jpeg, payload: jpeg, phase: "view-only paired screen")
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
        consent.controlAllowed = true
        server.setControlEnabled(true)
        server.setAudioSink(microphoneSink)
        try expectState(pairedClient, allowed: true, phase: "explicit control consent")
        guard writeExactly(pairedClient, Packet.encode(.control, clickData)) else {
            throw TestError.message("Paired control packet could not be sent")
        }
        guard delivered.waitForCount(1), delivered.count == 1 else {
            throw TestError.message("Trusted paired control did not reach the Mac automatically")
        }
        // Long text arrives in one piece, newlines and all.
        let pasted = ["Line one\nLine two\twith tab · 日本語 🙂\n",
                      String(repeating: "0123456789abcdef\n", count: 12_000)]
        for text in pasted {
            guard let payload = ClipboardPaste.encode(text),
                  writeExactly(pairedClient, Packet.encode(.paste, payload)) else {
                throw TestError.message("Paste packet could not be sent")
            }
        }
        guard pastes.waitForCount(2), pastes.texts == pasted else {
            throw TestError.message("Trusted paired paste did not reach the Mac intact")
        }
        server.setControlEnabled(false)
        try expectState(pairedClient, allowed: false, phase: "paired disable")
        guard writeExactly(pairedClient, Packet.encode(.control, clickData)) else {
            throw TestError.message("Control revoke packet could not be sent")
        }
        guard let revokedPaste = ClipboardPaste.encode("after revoke"),
              writeExactly(pairedClient, Packet.encode(.paste, revokedPaste)) else {
            throw TestError.message("Paste revoke packet could not be sent")
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard delivered.count == 1 else { throw TestError.message("Control worked after Mac revoked it") }
        guard pastes.texts.count == 2 else { throw TestError.message("Paste worked after Mac revoked control") }
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
        let phoneCode = server.enablePairing()
        let phonePair = PairingRequest.pair(code: phoneCode, id: phoneID, token: phoneToken,
                                            deviceName: "Test iPhone")
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
        guard let functionDown = ControlCommand(kind: .functionDown).encoded(),
              ControlCommand(kind: .functionDown, modifiers: [.function]).encoded() == nil,
              writeExactly(phoneClient, Packet.encode(.control, functionDown)),
              delivered.waitForCount(4), delivered.last?.kind == .functionDown else {
            throw TestError.message("Phone could not hold the Mac's Fn key")
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
        guard delivered.waitForCount(5), delivered.last?.kind == .functionUp else {
            throw TestError.message("Disconnecting phone left the Mac's Fn key held")
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
        let thirdID = UUID()
        let thirdCode = server.enablePairing()
        try expectRejected(address,
                           line: PairingRequest.pair(code: thirdCode, id: thirdID, token: token, deviceName: "Third device").line,
                           reason: "third simultaneous viewer")
        server.disablePairing()
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
        // A cellular receiver can stop reading briefly while TCP retransmits.
        // A delayed read must not discard an otherwise healthy paired session.
        let slowClient = try connect(to: address, receiveBuffer: 16_384)
        guard writeExactly(slowClient, Data(saved.line.utf8)),
              readExactly(slowClient, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Slow viewer could not authenticate")
        }
        try expectState(slowClient, allowed: true, phase: "slow viewer")
        try expectMicrophoneState(slowClient, allowed: true, phase: "slow viewer")
        let largeFrame = Data(repeating: 0x5a, count: 2_000_000)
        // Admission sent the previous frame; stay outside the legacy frame
        // interval so this frame is written before the audio.
        Thread.sleep(forTimeInterval: 0.2)
        server.publish(largeFrame)
        // Audio captured while a large video packet is blocked must remain
        // available once the cellular receiver catches up.
        for _ in 0..<40 { server.publishAudio(macAudio) }
        Thread.sleep(forTimeInterval: 0.7)
        guard server.viewerCount == 1 else {
            throw TestError.message("Slow viewer was disconnected before it resumed reading")
        }
        try expectPayload(slowClient, kind: .jpeg, payload: largeFrame, phase: "slow viewer frame")
        for index in 0..<40 {
            try expectPayload(slowClient, kind: .macAudio, payload: macAudio,
                              phase: "buffered audio packet \(index)")
        }
        Darwin.shutdown(slowClient, SHUT_RDWR)
        Darwin.close(slowClient)
        guard waitForViewerCount(server, 0) else {
            throw TestError.message("Slow viewer did not disconnect after closing")
        }
        // A longer outage must release the blocked connection, while the same
        // saved pairing remains usable afterward.
        let outage = try connect(to: address, receiveBuffer: 16_384)
        guard writeExactly(outage, Data(saved.line.utf8)), readExactly(outage, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Outage viewer could not authenticate")
        }
        try expectState(outage, allowed: true, phase: "outage setup")
        try expectMicrophoneState(outage, allowed: true, phase: "outage setup")
        server.publish(largeFrame)
        let outageDeadline = ProcessInfo.processInfo.systemUptime + 8
        while server.viewerCount > 0 && ProcessInfo.processInfo.systemUptime < outageDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Darwin.shutdown(outage, SHUT_RDWR)
        Darwin.close(outage)
        guard server.viewerCount == 0 else { throw TestError.message("Long blocked send did not release its viewer") }

        // Repeated replacement while writers are queued must not reuse a closed
        // descriptor underneath an old reader or corrupt a fresh auth response.
        for attempt in 0..<8 {
            let stalled = try connect(to: address, receiveBuffer: 16_384)
            guard writeExactly(stalled, Data(saved.line.utf8)),
                  readExactly(stalled, 3) == Data("OK\n".utf8) else {
                throw TestError.message("Replacement setup failed at \(attempt)")
            }
            try expectState(stalled, allowed: true, phase: "replacement setup")
            try expectMicrophoneState(stalled, allowed: true, phase: "replacement setup")
            server.publish(largeFrame)
            server.publishAudio(macAudio)
            let fresh = try connect(to: address)
            guard writeExactly(fresh, Data(saved.line.utf8)),
                  readExactly(fresh, 3) == Data("OK\n".utf8) else {
                throw TestError.message("Queued writer corrupted replacement auth at \(attempt)")
            }
            try expectState(fresh, allowed: true, phase: "replacement under load")
            try expectMicrophoneState(fresh, allowed: true, phase: "replacement under load")
            Darwin.shutdown(stalled, SHUT_RDWR)
            Darwin.close(stalled)
            Darwin.shutdown(fresh, SHUT_RDWR)
            Darwin.close(fresh)
            guard waitForViewerCount(server, 0) else {
                throw TestError.message("Replacement under load did not finish")
            }
        }
        // A viewer with frame flow control gets no frames while paused, at most
        // two unacknowledged frames, and then the newest frame, not a backlog.
        let flowClient = try connect(to: address)
        guard writeExactly(flowClient, Data(saved.line.utf8)),
              readExactly(flowClient, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Flow-control viewer could not authenticate")
        }
        try expectState(flowClient, allowed: true, phase: "flow setup")
        try expectMicrophoneState(flowClient, allowed: true, phase: "flow setup")
        func sendFlow(_ flow: VideoFlow) throws {
            guard writeExactly(flowClient, Packet.encode(.videoFlow, Data([flow.rawValue]))) else {
                throw TestError.message("Could not send video flow \(flow)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try sendFlow(.pause)
        _ = try nextFrame(flowClient, phase: "admission frame")
        let frames = (0..<4).map { Data(repeating: UInt8(0x60 + $0), count: 4_000) }
        server.publish(frames[0])
        guard try nextFrame(flowClient, phase: "paused") == nil else {
            throw TestError.message("Paused viewer received a frame")
        }
        try sendFlow(.resume)
        guard try nextFrame(flowClient, phase: "resume") == frames[0] else {
            throw TestError.message("Resume did not send the latest frame")
        }
        for frame in frames.dropFirst() { server.publish(frame) }
        guard try nextFrame(flowClient, phase: "second credit") == frames[1],
              try nextFrame(flowClient, phase: "no credit") == nil else {
            throw TestError.message("Viewer exceeded two unacknowledged frames")
        }
        try sendFlow(.received)
        guard try nextFrame(flowClient, phase: "acknowledged") == frames[3] else {
            throw TestError.message("Acknowledgment did not send the newest frame")
        }
        // After both sides offer AAC, the audio owner gets compressed Mac
        // sound and the Mac decodes compressed microphone audio.
        guard writeExactly(flowClient, Packet.encode(.capabilities, Data([AACAudio.capability]))) else {
            throw TestError.message("Could not send capabilities")
        }
        // The reply also offers paste, which viewers send only to Macs that offer it.
        try expectPayload(flowClient, kind: .capabilities,
                          payload: Data([AACAudio.capability | ClipboardPaste.capability]),
                          phase: "capabilities reply")
        func tone(channels: Int, frames: Int, offset: Int) -> Data {
            var pcm = Data(capacity: frames * channels * 2)
            for frame in 0..<frames {
                let value = Int16(8_000 * sin(2 * Double.pi * 440 * Double(offset + frame) / 48_000))
                for _ in 0..<channels { withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) } }
            }
            return pcm
        }
        for chunk in 0..<10 { server.publishAudio(tone(channels: 2, frames: 960, offset: chunk * 960)) }
        guard let macDecoder = AACDecoder(channels: 2) else { throw TestError.message("No AAC decoder") }
        var decodedMacAudio = Data()
        for _ in 0..<16 {
            guard let packet = readPacket(flowClient) else { break }
            if packet.kind == .macAudio { throw TestError.message("AAC viewer received PCM Mac sound") }
            if packet.kind == .macAudioAAC, let pcm = macDecoder.decode(packet.payload) { decodedMacAudio.append(pcm) }
            if decodedMacAudio.count >= 4 * AACAudio.framesPerPacket * 4 { break }
        }
        let macPeak = decodedMacAudio.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        guard macPeak > 4_000 else { throw TestError.message("AAC Mac sound did not decode to the tone (peak \(macPeak))") }
        guard let microphoneEncoder = AACEncoder(channels: 1, bitRate: 64_000) else {
            throw TestError.message("No AAC encoder")
        }
        let levelsBeforeAAC = microphoneLevels.count
        for chunk in 0..<10 {
            for packet in microphoneEncoder.encode(tone(channels: 1, frames: 960, offset: chunk * 960)) {
                guard writeExactly(flowClient, Packet.encode(.microphoneAAC, packet)) else {
                    throw TestError.message("Could not send AAC microphone audio")
                }
            }
        }
        guard microphoneLevels.waitForCount(levelsBeforeAAC + 1) else {
            throw TestError.message("Mac did not decode AAC microphone audio")
        }
        Darwin.shutdown(flowClient, SHUT_RDWR)
        Darwin.close(flowClient)
        guard waitForViewerCount(server, 0) else {
            throw TestError.message("Flow-control viewer did not disconnect")
        }
        // Turning off host consent persists through a saved-device reconnect.
        consent.controlAllowed = false
        server.setAudioSink(nil)
        let viewOnly = try connect(to: address)
        guard writeExactly(viewOnly, Data(saved.line.utf8)),
              readExactly(viewOnly, 3) == Data("OK\n".utf8) else {
            throw TestError.message("Saved view-only device could not reconnect")
        }
        try expectState(viewOnly, allowed: false, phase: "reconnect after control consent removed")
        try expectMicrophoneState(viewOnly, allowed: true, phase: "view-only Mac sound owner")
        let receivedBefore = microphoneSink.count
        guard writeExactly(viewOnly, Packet.encode(.microphone, microphone)) else {
            throw TestError.message("Could not send microphone after consent removed")
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard microphoneSink.count == receivedBefore else {
            throw TestError.message("Remote microphone reached Mac after routing consent was removed")
        }
        Darwin.shutdown(viewOnly, SHUT_RDWR)
        Darwin.close(viewOnly)
        guard waitForViewerCount(server, 0) else { throw TestError.message("View-only test viewer did not disconnect") }
        credentials.setUnavailable(true)
        try expectClosedWithoutRejection(address, line: saved.line, reason: "unreadable saved devices")
        credentials.setUnavailable(false)
        credentials.revoke(deviceID)
        try expectRejected(address, line: saved.line, reason: "revoked device")
        server.stop()
        if let unexpected = try? connect(to: address) {
            Darwin.close(unexpected)
            throw TestError.message("Stopped server still accepted a viewer")
        }
        print("Transport smoke passed: pairing consent, two simultaneous viewers, isolated frames, single audio owner, audio takeover and handoff across reconnects, trusted control, revocation, unreadable credentials not reported as revoked, stopped listener, session access denial, frame flow control, AAC audio both ways, clipboard paste only with control")
    }

    /// The next screen frame within 300 ms, skipping other packets.
    private static func nextFrame(_ fd: Int32, phase: String) throws -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 25)
            guard ready >= 0 else { throw TestError.message("Could not poll \(phase)") }
            if ready == 0 { continue }
            guard let packet = readPacket(fd) else { throw TestError.message("Viewer disconnected at \(phase)") }
            if packet.kind == .jpeg { return packet.payload }
        }
        return nil
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
        if case .authenticate = PairingRequest.parse(line.trimmingCharacters(in: .newlines)) {
            guard result == 1, byte == 78, readExactly(client, 2) == Data("O\n".utf8) else {
                throw TestError.message("Missing explicit rejection for \(reason)")
            }
            return
        }
        guard result == 0 else { throw TestError.message("Accepted \(reason) or timed out (recv=\(result), errno=\(errno))") }
    }

    /// A saved device the Mac cannot check must not be told it was revoked.
    private static func expectClosedWithoutRejection(_ address: String, line: String, reason: String) throws {
        let client = try connect(to: address)
        defer { Darwin.close(client) }
        guard writeExactly(client, Data(line.utf8)) else { throw TestError.message("Could not send \(reason)") }
        var byte: UInt8 = 0
        let result = Darwin.recv(client, &byte, 1, 0)
        guard result == 0 else { throw TestError.message("Answered \(reason) instead of closing (recv=\(result), byte=\(byte))") }
    }

    private static func connect(to address: String, receiveBuffer: Int32? = nil) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError.message("Socket failed") }
        if var receiveBuffer {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        }
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

private final class PasteRecorder {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var received = [String]()

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func append(_ text: String) {
        lock.lock(); received.append(text); lock.unlock()
        signal.signal()
    }

    func waitForCount(_ wanted: Int) -> Bool {
        while texts.count < wanted {
            if signal.wait(timeout: .now() + 2) != .success { return false }
        }
        return true
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

    var last: ControlCommand? {
        lock.lock(); defer { lock.unlock() }
        return commands.last
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

    private var unavailable = false

    func authenticate(_ id: UUID, token: String) -> VideoServer.SavedCredentialCheck {
        lock.lock(); defer { lock.unlock() }
        if unavailable { return .unavailable }
        return tokens[id] == token ? .accepted : .rejected
    }

    func setUnavailable(_ value: Bool) {
        lock.lock(); unavailable = value; lock.unlock()
    }

    func revoke(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        tokens.removeValue(forKey: id)
    }
}

private final class HostTestConsent {
    private let lock = NSLock()
    private var allowed = false
    var controlAllowed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return allowed }
        set { lock.lock(); allowed = newValue; lock.unlock() }
    }
}

private final class HostTestMicrophoneSink: AudioSinkOutput {
    private let lock = NSLock()
    private var received = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return received }
    func append(_ data: Data) { lock.lock(); received += 1; lock.unlock() }
    func clear() {}
}
