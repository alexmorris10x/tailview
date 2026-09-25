import CoreGraphics

enum SessionLockController {
    private static let qKeyCode: CGKeyCode = 12

    static func lockCurrentSession() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: qKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: qKeyCode, keyDown: false) else {
            return false
        }

        let lockFlags: CGEventFlags = [.maskCommand, .maskControl]
        keyDown.flags = lockFlags
        keyUp.flags = lockFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
