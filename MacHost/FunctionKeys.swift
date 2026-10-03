import CoreGraphics

/// A physical Mac keyboard's Fn layer is applied in keyboard hardware, so a
/// synthesized event carrying only the Fn flag does not change the key.
/// These translations reproduce that layer for remote keys.
enum FunctionKeys {
    /// Fn-Delete is forward delete; Fn-arrows are Home, End, Page Up, Page Down.
    static func keyCode(for key: ControlCommand.Key, function: Bool) -> CGKeyCode {
        switch key {
        case .returnKey: return 36
        case .tab: return 48
        case .delete: return function ? 117 : 51
        case .escape: return 53
        case .left: return function ? 115 : 123
        case .right: return function ? 119 : 124
        case .down: return function ? 121 : 125
        case .up: return function ? 116 : 126
        }
    }

    /// iOS keyboards have no F-key row, so Fn with the number row reaches
    /// F1 through F12, as on many compact keyboards.
    static func functionKeyCode(for character: Character) -> CGKeyCode? {
        let codes: [Character: CGKeyCode] = [
            "1": 122, "2": 120, "3": 99, "4": 118, "5": 96, "6": 97,
            "7": 98, "8": 100, "9": 101, "0": 109, "-": 103, "=": 111
        ]
        return codes[character]
    }
}
