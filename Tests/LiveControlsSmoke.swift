import Foundation

@main
struct LiveControlsSmoke {
    static func main() {
        // Entering the background: only running audio keeps TailView awake.
        precondition(!LiveControlsRules.stayUpInBackground(audioRunning: false, paused: false),
                     "A viewer without audio, or with both directions off, must end its controls")
        precondition(LiveControlsRules.stayUpInBackground(audioRunning: true, paused: false),
                     "The audio owner keeps running, so its controls stay up")
        precondition(LiveControlsRules.stayUpInBackground(audioRunning: false, paused: true),
                     "A pause is shown on purpose and must outlast the suspension")

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

        print("Live controls smoke passed: background lifetime and the delayed orange Mic")
    }
}
