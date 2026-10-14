import Foundation

/// When the lock-screen controls stay up, kept apart from ActivityKit so the
/// smoke test can check it.
enum LiveControlsRules {
    /// iOS suspends a background TailView within seconds unless its audio
    /// runs, as on a viewer while another device owns audio, and a suspended
    /// TailView can't confirm its controls, so they would go stale. A pause
    /// is meant to outlast the suspension, so it stays up.
    static func stayUpInBackground(audioRunning: Bool, paused: Bool) -> Bool {
        audioRunning || paused
    }
}

/// Reads true only once its input has stayed true for `delay`, so a brief
/// state, such as the seconds between audio moving to this device and its
/// microphone starting, never reaches the lock screen.
struct SustainedFlag {
    let delay: TimeInterval
    private(set) var trueSince: Date?

    init(delay: TimeInterval) { self.delay = delay }

    mutating func update(_ value: Bool, at now: Date = Date()) -> Bool {
        guard value else {
            trueSince = nil
            return false
        }
        let since = trueSince ?? now
        trueSince = since
        return now.timeIntervalSince(since) >= delay
    }
}
