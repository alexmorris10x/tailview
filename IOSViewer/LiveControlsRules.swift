import Foundation

/// When the lock-screen controls stay up, kept apart from ActivityKit so the
/// smoke test can check it.
enum LiveControlsRules {
    /// iOS suspends a background TailView within seconds unless its audio
    /// runs, as on a viewer while another device owns audio, and a suspended
    /// TailView can't confirm its controls, so they would go stale. Audio
    /// that is wanted on a device that may own it counts as running: an
    /// interruption, a microphone restart or a reconnect stops it only for a
    /// moment, and silent playback keeps TailView running meanwhile. A pause
    /// is meant to outlast the suspension, so it stays up.
    static func stayUpInBackground(audioRunning: Bool, audioWanted: Bool, mayOwnAudio: Bool,
                                   paused: Bool) -> Bool {
        audioRunning || (audioWanted && mayOwnAudio) || paused
    }
}

/// The pause a lock-screen tap shows when it finds nothing to act on, as on
/// controls left by a run iOS ended. It lasts until TailView is open or
/// connected, so it never sits on a working session.
struct TapPause {
    private(set) var isShown = false

    /// Whether the tap shows the pause instead of acting.
    mutating func tap(active: Bool, hasSession: Bool) -> Bool {
        guard !active, !hasSession else { return false }
        isShown = true
        return true
    }

    mutating func update(active: Bool, connected: Bool) {
        if active || connected { isShown = false }
    }
}

/// Drops a repeat of the same lock-screen action that arrives within
/// `window` of the one it accepted. On 15 Oct iOS ran TailView's intent
/// twice, 1–30 ms apart, for clicks on the copy of the controls in the Mac's
/// menu bar, so a toggle undid itself; taps on the iPhone came once. A real
/// second tap comes later.
struct RepeatFilter<Action: Equatable> {
    let window: TimeInterval
    private var accepted: (action: Action, at: Date)?

    init(window: TimeInterval) { self.window = window }

    mutating func accept(_ action: Action, at now: Date = Date()) -> Bool {
        if let accepted, accepted.action == action, now.timeIntervalSince(accepted.at) < window {
            return false
        }
        accepted = (action, now)
        return true
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
