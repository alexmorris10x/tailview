import Foundation

/// Retargets a running microphone tap only after the new connection receives
/// audio ownership. Disconnected samples are never stored for later upload.
final class AudioConnectionGate<Connection: AnyObject> {
    struct Ticket {
        let connection: Connection
        let capture: UInt64
        let route: UInt64
        let frames: Int
    }

    private let lock = NSLock()
    private let maximumFrames: Int
    private var connection: Connection?
    private var capture: UInt64 = 0
    private var route: UInt64 = 0
    private var pendingFrames = 0

    init(maximumFrames: Int = 96_000) { self.maximumFrames = maximumFrames }

    @discardableResult
    func resetCapture() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        capture &+= 1
        pendingFrames = 0
        return capture
    }

    func setConnection(_ connection: Connection?) {
        lock.lock(); defer { lock.unlock() }
        self.connection = connection
        route &+= 1
        pendingFrames = 0
    }

    func reserve(frames: Int, capture expected: UInt64) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard expected == capture, let connection, frames > 0,
              frames <= maximumFrames - pendingFrames else { return nil }
        pendingFrames += frames
        return Ticket(connection: connection, capture: capture, route: route, frames: frames)
    }

    func complete(_ ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }
        guard ticket.capture == capture, ticket.route == route else { return }
        pendingFrames = max(0, pendingFrames - ticket.frames)
    }
}
