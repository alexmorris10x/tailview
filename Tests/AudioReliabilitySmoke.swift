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

        let budget = AudioSendBudget()
        let generation = budget.reset()
        for _ in 0..<100 { precondition(budget.reserve(frames: 960, generation: generation)) }
        precondition(!budget.reserve(frames: 1, generation: generation), "Pending voice must be duration-bounded")
        budget.complete(frames: 19_200, generation: generation)
        precondition(budget.reserve(frames: 19_200, generation: generation))
        let next = budget.reset()
        precondition(budget.reserve(frames: 96_000, generation: next))
        budget.complete(frames: 96_000, generation: generation)
        precondition(!budget.reserve(frames: 1, generation: next), "Old completions cannot release new capture capacity")
        precondition(!budget.reserve(frames: 960, generation: generation), "Old taps cannot send after reset")

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
        print("Audio reliability smoke passed: startup/refill, 20s burst jitter, fades, bounded backlog, owner reset, send budget generations, fragmented auth and transient disconnects")
    }
}
