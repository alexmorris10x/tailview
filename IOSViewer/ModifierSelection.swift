import Foundation

/// Modifier state stays on the viewer. Each remote action carries its own flags,
/// so losing the connection cannot leave a modifier pressed on the Mac.
struct ModifierSelection {
    enum Mode: Equatable { case off, next, held }

    private(set) var next = Set<ControlCommand.Modifier>()
    private(set) var held = Set<ControlCommand.Modifier>()
    private var firstTapAt = [ControlCommand.Modifier: TimeInterval]()
    private let doubleTapInterval: TimeInterval = 0.35

    var active: [ControlCommand.Modifier]? {
        let selected = ControlCommand.Modifier.allCases.filter { next.contains($0) || held.contains($0) }
        return selected.isEmpty ? nil : selected
    }

    func mode(for modifier: ControlCommand.Modifier) -> Mode {
        if held.contains(modifier) { return .held }
        return next.contains(modifier) ? .next : .off
    }

    mutating func tap(_ modifier: ControlCommand.Modifier,
                      at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if held.remove(modifier) != nil {
            firstTapAt.removeValue(forKey: modifier)
        } else if next.contains(modifier) {
            next.remove(modifier)
            if let first = firstTapAt[modifier], time >= first,
               time - first <= doubleTapInterval {
                held.insert(modifier)
            }
            firstTapAt.removeValue(forKey: modifier)
        } else {
            next.insert(modifier)
            firstTapAt[modifier] = time
        }
    }

    mutating func hold(_ modifier: ControlCommand.Modifier) {
        next.remove(modifier)
        held.insert(modifier)
        firstTapAt.removeValue(forKey: modifier)
    }

    mutating func consumeNext() {
        next.removeAll()
        firstTapAt.removeAll()
    }

    mutating func reset() {
        consumeNext()
        held.removeAll()
    }
}
