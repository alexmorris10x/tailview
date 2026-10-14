import Foundation

@main
struct AudioReliabilitySmoke {
    static func main() {
        func pcm(_ count: Int, _ sample: Int16 = 12_000) -> Data {
            [Int16](repeating: sample, count: count).withUnsafeBytes { Data($0) }
        }
        func render(_ buffer: inout AudioJitterBuffer, _ frames: Int = 960) -> [Int16] {
            var output = [Int16](repeating: -1, count: frames * 2)
            output.withUnsafeMutableBufferPointer { buffer.render(into: $0.baseAddress!, frames: frames) }
            return output
        }

        var buffer = AudioJitterBuffer()
        buffer.append(pcm(28_799))
        precondition(render(&buffer).allSatisfy { $0 == 0 } && buffer.count == 28_799,
                     "Playback must retain data until the startup target is reached")
        buffer.append(pcm(1))
        let first = render(&buffer)
        precondition(first[0] > 0 && first[0] < first[478] && first[480] == 12_000,
                     "Startup should fade in without a discontinuity")
        precondition(stride(from: 0, to: first.count, by: 2).allSatisfy { first[$0] == first[$0 + 1] },
                     "Mono voice must reach both BlackHole channels")
        // Deliver the next 400 ms as a single burst every 400 ms, for 20 seconds.
        for tick in 0..<1_000 {
            if tick % 20 == 0 { buffer.append(pcm(19_200)) }
            precondition(render(&buffer).allSatisfy { $0 == 12_000 }, "Short jitter burst caused a gap")
        }
        precondition(buffer.underruns == 0)

        while buffer.count > 960 { _ = render(&buffer) }
        let tail = render(&buffer)
        precondition(tail.last == 0 && buffer.isBuffering && buffer.underruns == 1,
                     "A drained stream must fade to silence and wait to refill")
        for _ in 0..<10 {
            buffer.append(pcm(960))
            precondition(render(&buffer).allSatisfy { $0 == 0 }, "Recovery must not chatter on every packet")
        }
        buffer.append(pcm(19_200))
        precondition(render(&buffer).contains(12_000) && !buffer.isBuffering)
        buffer.append(pcm(144_000, 6_000))
        precondition(buffer.count == 28_800 && buffer.droppedFrames > 0,
                     "A long backlog must catch up to fresh sound within a bounded buffer")
        precondition(render(&buffer).dropFirst(480).allSatisfy { $0 == 6_000 })
        buffer.clear()
        precondition(render(&buffer).allSatisfy { $0 == 0 } && buffer.isBuffering,
                     "Disconnect/owner change must discard old audio")
        buffer.append(Data([1]))
        precondition(buffer.count == 0, "Malformed PCM must be ignored")

        let firstConnection = NSObject()
        let secondConnection = NSObject()
        let gate = AudioConnectionGate<NSObject>()
        let capture = gate.resetCapture()
        precondition(gate.reserve(frames: 960, capture: capture) == nil,
                     "No microphone samples may queue before audio authorization")
        gate.setConnection(firstConnection)
        var tickets = [AudioConnectionGate<NSObject>.Ticket]()
        for _ in 0..<100 { tickets.append(gate.reserve(frames: 960, capture: capture)!) }
        precondition(gate.reserve(frames: 1, capture: capture) == nil, "Pending voice must be duration-bounded")
        gate.complete(tickets[0])
        precondition(gate.reserve(frames: 960, capture: capture) != nil)
        gate.setConnection(nil)
        precondition(gate.reserve(frames: 960, capture: capture) == nil,
                     "An ongoing microphone must discard samples throughout the outage")
        gate.setConnection(secondConnection)
        let resumed = gate.reserve(frames: 96_000, capture: capture)!
        precondition(resumed.connection === secondConnection, "The same tap must send to the reauthorized connection")
        tickets.forEach { gate.complete($0) }
        precondition(gate.reserve(frames: 1, capture: capture) == nil, "Old network completions cannot release the new route's budget")
        let nextCapture = gate.resetCapture()
        precondition(gate.reserve(frames: 960, capture: capture) == nil, "A stopped tap cannot send into a new capture")
        precondition(gate.reserve(frames: 96_000, capture: nextCapture) != nil)
        gate.complete(resumed)
        precondition(gate.reserve(frames: 1, capture: nextCapture) == nil)
        gate.setConnection(nil)
        precondition(gate.reserve(frames: 960, capture: nextCapture) == nil, "Revocation must stop microphone delivery")
        var backoff = ReconnectBackoff()
        precondition((0..<7).map { _ in backoff.nextDelay() } == [1, 2, 4, 8, 8, 8, 8])
        backoff.reset()
        precondition(backoff.nextDelay() == 1, "A successful connection must reset retry delay")
        let lost = Date()
        let grace = ReconnectBackoff.backgroundGracePeriod
        precondition(grace >= 60 && grace <= 300, "Background retries must be bounded to a few minutes")
        precondition(ReconnectBackoff.backgroundGraceFailures >= 2)
        func fail(_ backoff: inout ReconnectBackoff, times: Int, at time: Date) {
            for _ in 0..<times { backoff.connectionLost(at: time) }
        }
        precondition(!backoff.backgroundGraceExpired(at: lost + 3_600), "No outage, nothing to pause")
        backoff.restartBackgroundGrace(at: lost + 3_000)
        precondition(backoff.graceStart == nil, "Going to the background while connected starts nothing")
        backoff.connectionLost(at: lost)
        fail(&backoff, times: 5, at: lost + grace - 1)
        precondition(!backoff.backgroundGraceExpired(at: lost + grace),
                     "Brief outages and dictation interruptions must keep retrying")
        precondition(backoff.backgroundGraceExpired(at: lost + grace + 1),
                     "Later failures must not restart the grace period")
        // An outage watched in the foreground gets the full allowance once
        // TailView goes to the background, and an interruption wake restarts it.
        let backgrounded = lost + 3 * grace
        backoff.restartBackgroundGrace(at: backgrounded)
        fail(&backoff, times: 10, at: backgrounded + 1)
        precondition(!backoff.backgroundGraceExpired(at: backgrounded + grace),
                     "Moving to the background must restart the grace period")
        precondition(backoff.backgroundGraceExpired(at: backgrounded + grace + 1))
        let woken = backgrounded + 2 * grace
        backoff.restartBackgroundGrace(at: woken)
        fail(&backoff, times: ReconnectBackoff.backgroundGraceFailures - 1, at: woken + grace + 1)
        precondition(!backoff.backgroundGraceExpired(at: woken + grace + 1),
                     "A wake that fails at once while the network returns must not pause")
        backoff.connectionLost(at: woken + grace + 1)
        precondition(backoff.backgroundGraceExpired(at: woken + grace + 1),
                     "Enough failures after the allowance must pause")
        backoff.reset()
        precondition(!backoff.backgroundGraceExpired(at: woken + 10 * grace) && backoff.graceStart == nil,
                     "A reconnect must restart the grace period")

        let ok = Data("OK\n".utf8)
        func reply(_ text: String, ended: Bool = false) -> AuthenticationReply {
            AuthenticationReply.parse(Data(text.utf8), expected: ok, savedCredential: true, streamEnded: ended)
        }
        precondition(reply("") == .pending && reply("O") == .pending && reply("OK") == .pending)
        precondition(reply("OK\n") == .accepted)
        precondition(reply("", ended: true) == .unavailable && reply("O", ended: true) == .unavailable)
        precondition(reply("OK\n", ended: true) == .unavailable, "Closed authentication stream must retry")
        precondition(reply("N") == .pending && reply("NO") == .pending)
        precondition(reply("NO\n") == .rejected && reply("NO\n", ended: true) == .rejected)
        precondition(reply("NO", ended: true) == .unavailable && reply("BAD") == .invalid)
        print("Audio reliability smoke passed: startup/refill, 20s burst jitter, fades, bounded backlog, owner reset, reauthorized microphone retargeting, bounded retry delays, bounded background retries, fragmented auth and transient disconnects")
    }
}
