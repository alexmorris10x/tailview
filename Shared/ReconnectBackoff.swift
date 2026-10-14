import Foundation

struct ReconnectBackoff {
    /// How long a viewer in the background keeps retrying an unreachable Mac,
    /// with its audio kept running so iOS doesn't suspend it. That covers brief
    /// outages and dictation interruptions; after it, the viewer pauses until
    /// TailView returns to the foreground instead of holding the microphone.
    static let backgroundGracePeriod: TimeInterval = 120
    /// Failed connections the grace period also needs, so a wake that fails
    /// at once while the network comes back cannot pause by itself.
    static let backgroundGraceFailures = 3

    private(set) var attempts = 0
    /// Start of the current allowance: the connection loss, or the latest
    /// move to the background or interruption wake during the outage.
    /// Nil while connected.
    private(set) var graceStart: Date?
    private(set) var failuresSinceGraceStart = 0

    mutating func nextDelay() -> TimeInterval {
        let delay = TimeInterval(1 << min(attempts, 3))
        attempts += 1
        return delay
    }

    /// Call on every lost or failed connection; the first starts the outage.
    mutating func connectionLost(at now: Date = Date()) {
        if graceStart == nil { graceStart = now }
        failuresSinceGraceStart += 1
    }

    /// TailView entered the background, or iOS woke it when an interruption
    /// ended. An outage in progress gets a full allowance from now.
    mutating func restartBackgroundGrace(at now: Date = Date()) {
        guard graceStart != nil else { return }
        graceStart = now
        failuresSinceGraceStart = 0
    }

    func backgroundGraceExpired(at now: Date = Date()) -> Bool {
        guard let graceStart else { return false }
        return now.timeIntervalSince(graceStart) > Self.backgroundGracePeriod &&
            failuresSinceGraceStart >= Self.backgroundGraceFailures
    }

    /// A connection succeeded, or the user started or resumed one.
    mutating func reset() {
        attempts = 0
        graceStart = nil
        failuresSinceGraceStart = 0
    }
}
