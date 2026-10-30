import Foundation

/// A verified purchase snapshot shared by UI, network and audio callbacks.
/// Pairing does not use this gate; viewing, audio and input always do.
final class StreamAccessGate {
    private let lock = NSLock()
    private var allowed = false
    private var expiresAt: Date?

    func update(allowed: Bool, expiresAt: Date?) {
        lock.lock()
        self.allowed = allowed
        self.expiresAt = expiresAt
        lock.unlock()
    }

    func permits(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed && (expiresAt.map { date < $0 } ?? true)
    }
}
