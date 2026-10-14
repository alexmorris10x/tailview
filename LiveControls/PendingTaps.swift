import Foundation

/// Lock-screen taps that arrived before the app could handle them. A tap
/// older than `lifetime` is dropped, so one that started TailView without
/// its window isn't applied minutes later when TailView opens.
struct PendingTaps<Action> {
    let lifetime: TimeInterval
    private var taps = [(action: Action, at: Date)]()

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    var isEmpty: Bool { taps.isEmpty }

    mutating func add(_ action: Action, at now: Date = Date()) {
        taps.append((action, now))
    }

    /// The taps still fresh, oldest first; empties the queue.
    mutating func take(at now: Date = Date()) -> [Action] {
        defer { taps = [] }
        return taps.filter { now.timeIntervalSince($0.at) <= lifetime }.map(\.action)
    }
}
