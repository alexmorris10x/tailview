import AppKit
import CoreGraphics
import Foundation

/// Posts only validated viewer actions while a paired, locally approved session is active.
final class ControlInjector {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "TailView.controlEvents")
    private var enabled = false
    private var generation: UInt64 = 0
    private var mouseIsDown = false
    private var functionIsDown = false
    private var lastPoint = CGPoint.zero

    static func hasPermission() -> Bool { CGPreflightPostEventAccess() }

    static func requestPermission() -> Bool { CGRequestPostEventAccess() }

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        enabled = value
        if !value {
            releaseHeldMouse()
            setFunctionKey(down: false)
        }
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

    /// Puts text on the Mac clipboard as plain text and presses Command-V in
    /// the focused app; the bar's modifiers never apply. It shares the queue
    /// with other actions, so text typed around a paste keeps its order.
    func paste(_ text: String) {
        lock.lock()
        let acceptedGeneration = enabled ? generation : nil
        lock.unlock()
        guard let acceptedGeneration else { return }
        queue.async { [weak self] in
            guard let self, self.isCurrent(acceptedGeneration) else { return }
            // AppKit on the main thread, without holding the lock that
            // setEnabled takes.
            DispatchQueue.main.sync {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.enabled, self.generation == acceptedGeneration else { return }
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: isDown) else { continue }
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func isCurrent(_ acceptedGeneration: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && generation == acceptedGeneration
    }

    private func post(_ command: ControlCommand) {
        let point = command.x.flatMap { x in command.y.map { Self.displayPoint(x: x, y: $0) } }
        let flags = Self.eventFlags(for: command.modifiers)
        if let point { lastPoint = point }
        switch command.kind {
        case .move:
            if let point { postMouse(.mouseMoved, at: point, flags: flags) }
        case .leftClick:
            if let point {
                releaseHeldMouse()
                postMouse(.leftMouseDown, at: point, flags: flags)
                postMouse(.leftMouseUp, at: point, flags: flags)
            }
        case .rightClick:
            if let point {
                releaseHeldMouse()
                postMouse(.rightMouseDown, at: point, button: .right, flags: flags)
                postMouse(.rightMouseUp, at: point, button: .right, flags: flags)
            }
        case .leftDown:
            if let point, !mouseIsDown {
                postMouse(.leftMouseDown, at: point, flags: flags)
                mouseIsDown = true
            }
        case .leftDrag:
            if let point { postMouse(mouseIsDown ? .leftMouseDragged : .mouseMoved, at: point, flags: flags) }
        case .leftUp:
            if let point, mouseIsDown {
                postMouse(.leftMouseUp, at: point, flags: flags)
                mouseIsDown = false
            }
        case .scroll:
            let vertical = command.amount ?? 0
            let horizontal = command.horizontalAmount ?? 0
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                   wheelCount: horizontal == 0 ? 1 : 2,
                                   wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        case .text:
            if let text = command.text { postText(text, flags: flags) }
        case .key:
            if let key = command.key { postKey(key, flags: flags) }
        case .window:
            if let layout = command.window {
                Task { @MainActor in WindowArranger.arrange(layout) }
            }
        case .functionDown:
            setFunctionKey(down: true)
        case .functionUp:
            setFunctionKey(down: false)
        }
    }

    /// Posts the Fn key's own flags-changed event, as a physical keyboard does
    /// when Fn is pressed alone. Disabling control releases a held Fn key.
    private func setFunctionKey(down: Bool) {
        guard functionIsDown != down,
              let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        event.post(tap: .cghidEventTap)
        functionIsDown = down
    }

    private static func eventFlags(for modifiers: [ControlCommand.Modifier]?) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers ?? [] {
            switch modifier {
            case .function: flags.insert(.maskSecondaryFn)
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .command: flags.insert(.maskCommand)
            }
        }
        return flags
    }

    private static func displayPoint(x: Double, y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: bounds.minX + x * max(0, bounds.width - 1),
                       y: bounds.minY + y * max(0, bounds.height - 1))
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint,
                           button: CGMouseButton = .left, flags: CGEventFlags = []) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func releaseHeldMouse() {
        guard mouseIsDown else { return }
        postMouse(.leftMouseUp, at: lastPoint)
        mouseIsDown = false
    }

    private func postText(_ text: String, flags: CGEventFlags) {
        for character in text {
            let units = Array(String(character).utf16)
            // A shortcut needs the actual keycode. Some Mac apps ignore the
            // Unicode override and inspect only keycode plus modifier flags.
            let functionKey = flags.contains(.maskSecondaryFn)
                ? FunctionKeys.functionKeyCode(for: character) : nil
            let modifiedKey = functionKey.map { (code: $0, extraFlags: CGEventFlags()) }
                ?? (flags.isEmpty ? nil : Self.shortcutKey(for: character))
            if !flags.isEmpty && modifiedKey == nil { continue }
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil,
                                          virtualKey: modifiedKey?.code ?? 0,
                                          keyDown: isDown) else { continue }
                event.flags = flags.union(modifiedKey?.extraFlags ?? [])
                if modifiedKey == nil {
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// ANSI key positions cover the shortcut characters produced by the iOS
    /// keyboard. Unsupported modified characters are ignored rather than being
    /// misread as virtual key zero (A) by a Mac app.
    private static func shortcutKey(for character: Character) -> (code: CGKeyCode, extraFlags: CGEventFlags)? {
        let letterCodes: [Character: CGKeyCode] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
            "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
            "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
            "v": 9, "w": 13, "x": 7, "y": 16, "z": 6
        ]
        if let code = letterCodes[Character(String(character).lowercased())] {
            return (code, String(character) == String(character).uppercased() ? .maskShift : [])
        }
        let keyCodes: [Character: CGKeyCode] = [
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
            "8": 28, "9": 25, "0": 29, "=": 24, "-": 27, "]": 30,
            "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44,
            ".": 47, "`": 50, " ": 49
        ]
        if let code = keyCodes[character] { return (code, []) }
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
            "*": "8", "(": "9", ")": "0", "+": "=", "_": "-", "}": "]",
            "{": "[", "\"": "'", ":": ";", "|": "\\", "<": ",", "?": "/",
            ">": ".", "~": "`"
        ]
        if let base = shifted[character], let code = keyCodes[base] { return (code, .maskShift) }
        return nil
    }

    private func postKey(_ key: ControlCommand.Key, flags: CGEventFlags) {
        let code = FunctionKeys.keyCode(for: key, function: flags.contains(.maskSecondaryFn))
        // Physical arrow keys carry the function and keypad flags. macOS
        // system shortcuts such as Control-arrow for Spaces require them.
        let isArrow = [123, 124, 125, 126].contains(code)
        let keyFlags = isArrow ? flags.union([.maskSecondaryFn, .maskNumericPad]) : flags
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown) else { continue }
            event.flags = keyFlags
            event.post(tap: .cghidEventTap)
        }
    }
}
