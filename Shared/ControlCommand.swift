import Foundation

/// A deliberately small allowlist of actions a paired viewer can ask the Mac to perform.
struct ControlCommand: Codable, Equatable {
    enum Kind: String, Codable {
        case move, leftClick, rightClick, leftDown, leftDrag, leftUp, scroll, text, key
    }

    enum Key: String, Codable {
        case returnKey, tab, delete, escape, left, right, up, down
    }

    let kind: Kind
    var x: Double? = nil
    var y: Double? = nil
    var amount: Int? = nil
    var text: String? = nil
    var key: Key? = nil

    static let maximumBytes = 1_024

    static func decode(_ data: Data) -> ControlCommand? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let command = try? JSONDecoder().decode(ControlCommand.self, from: data),
              command.isValid else { return nil }
        return command
    }

    func encoded() -> Data? {
        guard isValid, let data = try? JSONEncoder().encode(self),
              data.count <= Self.maximumBytes else { return nil }
        return data
    }

    private var hasPoint: Bool {
        guard let x, let y else { return false }
        return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

    private var isValid: Bool {
        switch kind {
        case .move, .leftClick, .rightClick, .leftDown, .leftDrag, .leftUp:
            return hasPoint && amount == nil && text == nil && key == nil
        case .scroll:
            return x == nil && y == nil && amount.map { (-20...20).contains($0) && $0 != 0 } == true
                && text == nil && key == nil
        case .text:
            return x == nil && y == nil && amount == nil && key == nil
                && text.map { !$0.isEmpty && $0.utf16.count <= 64
                    && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } == true
        case .key:
            return x == nil && y == nil && amount == nil && text == nil && key != nil
        }
    }
}
