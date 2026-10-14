import Foundation

@main
struct LiveControlsSmoke {
    static func main() {
        // Entering the background: only audio that runs, or will run, keeps TailView awake.
        func stays(running: Bool = false, wanted: Bool = false, mayOwn: Bool = false, paused: Bool = false) -> Bool {
            LiveControlsRules.stayUpInBackground(audioRunning: running, audioWanted: wanted,
                                                 mayOwnAudio: mayOwn, paused: paused)
        }
        precondition(!stays(wanted: true), "A viewer while another device owns audio must end its controls")
        precondition(!stays(mayOwn: true), "An audio owner with both directions off must end its controls")
        precondition(stays(running: true, wanted: true, mayOwn: true), "The running audio owner keeps them")
        precondition(stays(wanted: true, mayOwn: true),
                     "An owner whose audio is briefly down (interruption, mic restart) keeps them")
        precondition(stays(paused: true), "A pause is shown on purpose and must outlast the suspension")

        // A repeated delivery of one tap within 0.5 s toggles once; a real second tap still counts.
        var repeats = RepeatFilter<String>(window: 0.5)
        let tap = Date(timeIntervalSince1970: 100)
        precondition(repeats.accept("mic", at: tap))
        precondition(!repeats.accept("mic", at: tap.addingTimeInterval(0.001)), "A pair 1 ms apart must toggle once")
        precondition(!repeats.accept("mic", at: tap.addingTimeInterval(0.03)))
        precondition(repeats.accept("sound", at: tap.addingTimeInterval(0.04)), "A different button is a new tap")
        precondition(repeats.accept("mic", at: tap.addingTimeInterval(0.1)), "Mic after Sound is a new tap")
        precondition(repeats.accept("mic", at: tap.addingTimeInterval(0.7)), "A second tap after 0.5 s must work")
        precondition(!repeats.accept("mic", at: tap.addingTimeInterval(0.72)))
        precondition(repeats.accept("mic", at: tap.addingTimeInterval(1.21)),
                     "Dropped repeats must not extend the window")

        // A tap with nothing to act on shows the pause until TailView is open or connected.
        var pause = TapPause()
        precondition(!pause.tap(active: false, hasSession: true) && !pause.isShown,
                     "A tap during a session or reconnect acts instead")
        precondition(!pause.tap(active: true, hasSession: false) && !pause.isShown, "An open TailView never pauses")
        precondition(pause.tap(active: false, hasSession: false) && pause.isShown)
        pause.update(active: false, connected: false)
        precondition(pause.isShown, "The pause lasts while TailView stays closed and unconnected")
        pause.update(active: true, connected: false)
        precondition(!pause.isShown, "Opening TailView, also on a cold launch, clears the pause")
        _ = pause.tap(active: false, hasSession: false)
        pause.update(active: false, connected: true)
        precondition(!pause.isShown, "A connection clears the pause")

        // Taps queued before the handler exists expire after ten seconds.
        var pending = PendingTaps<String>(lifetime: 10)
        precondition(pending.isEmpty && pending.take().isEmpty)
        pending.add("mic", at: tap)
        pending.add("sound", at: tap.addingTimeInterval(4))
        precondition(pending.take(at: tap.addingTimeInterval(9)) == ["mic", "sound"], "Fresh taps run in order")
        precondition(pending.isEmpty, "Taking empties the queue")
        pending.add("mic", at: tap)
        pending.add("sound", at: tap.addingTimeInterval(8))
        precondition(pending.take(at: tap.addingTimeInterval(12)) == ["sound"], "A tap older than ten seconds is dropped")
        pending.add("mic", at: tap)
        precondition(pending.take(at: tap.addingTimeInterval(300)).isEmpty, "A tap from minutes ago never applies")

        // The lock screen's orange Mic waits five seconds; a brief state never shows.
        let start = Date(timeIntervalSince1970: 0)
        var attention = SustainedFlag(delay: 5)
        precondition(!attention.update(false, at: start))
        precondition(!attention.update(true, at: start), "Attention must not show at once")
        precondition(!attention.update(true, at: start.addingTimeInterval(4.9)))
        precondition(!attention.update(false, at: start.addingTimeInterval(5)),
                     "Microphone started: attention clears at once")
        precondition(!attention.update(true, at: start.addingTimeInterval(6)),
                     "A new spell of attention starts the wait again")
        precondition(!attention.update(true, at: start.addingTimeInterval(10.9)))
        precondition(attention.update(true, at: start.addingTimeInterval(11)),
                     "Attention that lasts five seconds shows")
        precondition(attention.update(true, at: start.addingTimeInterval(60)))
        precondition(!attention.update(false, at: start.addingTimeInterval(61)) && attention.trueSince == nil)

        print("Live controls smoke passed: background lifetime, repeated taps, tap pause, queued tap expiry, and the delayed orange Mic")
    }
}
