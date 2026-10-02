import Foundation

struct ReconnectBackoff {
    private(set) var attempts = 0

    mutating func nextDelay() -> TimeInterval {
        let delay = TimeInterval(1 << min(attempts, 3))
        attempts += 1
        return delay
    }

    mutating func reset() { attempts = 0 }
}
