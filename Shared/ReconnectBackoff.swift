import Foundation

struct ReconnectBackoff {
    /// How long a viewer in the background keeps retrying an unreachable Mac,
    /// with its audio kept running so iOS doesn't suspend it. That covers brief
    /// outages and dictation interruptions; after it, the viewer pauses until
    /// TailView returns to the foreground instead of holding the microphone.
    static let backgroundGracePeriod: TimeInterval = 120

    private(set) var attempts = 0
    /// When the current outage began; nil while connected.
    private(set) var outageStart: Date?

    mutating func nextDelay() -> TimeInterval {
        let delay = TimeInterval(1 << min(attempts, 3))
        attempts += 1
        return delay
    }

    /// Call on every lost or failed connection; the first starts the outage.
    mutating func connectionLost(at now: Date = Date()) {
        if outageStart == nil { outageStart = now }
    }

    func backgroundGraceExpired(at now: Date = Date()) -> Bool {
        guard let outageStart else { return false }
        return now.timeIntervalSince(outageStart) > Self.backgroundGracePeriod
    }

    /// A connection succeeded, or the user started or resumed one.
    mutating func reset() {
        attempts = 0
        outageStart = nil
    }
}
