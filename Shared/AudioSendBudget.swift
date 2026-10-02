import Foundation

/// Bounds queued microphone audio by duration, independent of hardware tap
/// size. A previous capture's completions cannot release the new one's budget.
final class AudioSendBudget {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingFrames = 0
    private let maximumFrames: Int

    init(maximumFrames: Int = 96_000) { self.maximumFrames = maximumFrames }

    @discardableResult
    func reset() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        pendingFrames = 0
        return generation
    }

    func reserve(frames: Int, generation expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard expected == generation, frames > 0, frames <= maximumFrames - pendingFrames else { return false }
        pendingFrames += frames
        return true
    }

    func complete(frames: Int, generation expected: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard expected == generation else { return }
        pendingFrames = max(0, pendingFrames - frames)
    }
}
