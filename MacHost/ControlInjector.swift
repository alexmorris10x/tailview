import CoreGraphics
import Foundation

/// Posts only validated viewer actions while a paired, locally approved session is active.
final class ControlInjector {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "TailView.controlEvents")
    private var enabled = false
    private var generation: UInt64 = 0
    private var mouseIsDown = false
    private var lastPoint = CGPoint.zero

    static func hasPermission() -> Bool { CGPreflightPostEventAccess() }

    static func requestPermission() -> Bool { CGRequestPostEventAccess() }

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        enabled = value
        if !value { releaseHeldMouse() }
    }

    func submit(_ command: ControlCommand) {
        lock.lock()
        let acceptedGeneration = enabled ? generation : nil
        lock.unlock()
        guard let acceptedGeneration else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.enabled, self.generation == acceptedGeneration else { return }
            self.post(command)
        }
    }

    private func post(_ command: ControlCommand) {
        let point = command.x.flatMap { x in command.y.map { Self.displayPoint(x: x, y: $0) } }
        if let point { lastPoint = point }
        switch command.kind {
        case .move:
            if let point { postMouse(.mouseMoved, at: point) }
        case .leftClick:
            if let point {
                releaseHeldMouse()
                postMouse(.leftMouseDown, at: point)
                postMouse(.leftMouseUp, at: point)
            }
        case .rightClick:
            if let point {
                releaseHeldMouse()
                postMouse(.rightMouseDown, at: point, button: .right)
                postMouse(.rightMouseUp, at: point, button: .right)
            }
        case .leftDown:
            if let point, !mouseIsDown {
                postMouse(.leftMouseDown, at: point)
                mouseIsDown = true
            }
        case .leftDrag:
            if let point { postMouse(mouseIsDown ? .leftMouseDragged : .mouseMoved, at: point) }
        case .leftUp:
            if let point, mouseIsDown {
                postMouse(.leftMouseUp, at: point)
                mouseIsDown = false
            }
        case .scroll:
            let vertical = command.amount ?? 0
            let horizontal = command.horizontalAmount ?? 0
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                   wheelCount: horizontal == 0 ? 1 : 2,
                                   wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }
        case .text:
            if let text = command.text { postText(text) }
        case .key:
            if let key = command.key { postKey(key) }
        }
    }

    private static func displayPoint(x: Double, y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: bounds.minX + x * max(0, bounds.width - 1),
                       y: bounds.minY + y * max(0, bounds.height - 1))
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func releaseHeldMouse() {
        guard mouseIsDown else { return }
        postMouse(.leftMouseUp, at: lastPoint)
        mouseIsDown = false
    }

    private func postText(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { continue }
                units.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func postKey(_ key: ControlCommand.Key) {
        let code: CGKeyCode
        switch key {
        case .returnKey: code = 36
        case .tab: code = 48
        case .delete: code = 51
        case .escape: code = 53
        case .left: code = 123
        case .right: code = 124
        case .down: code = 125
        case .up: code = 126
        }
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
