import AppKit
import CoreGraphics
import Foundation

/// Checks the local-input shield policy without installing an event tap.
@main
struct DisplayControlSmoke {
    static func main() throws {
        let shield = LocalInputController()
        let point = CGPoint(x: 10, y: 10)

        // ControlInjector creates events with a nil source.
        let remoteMove = try unwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                            mouseCursorPosition: point, mouseButton: .left))
        let remoteKey = try unwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        try check(!shield.shouldBlockShieldEvent(type: .mouseMoved, event: remoteMove),
                  "Shield blocked TailView remote pointer events")
        try check(!shield.shouldBlockShieldEvent(type: .keyDown, event: remoteKey),
                  "Shield blocked TailView remote key events")

        let privateSource = try unwrap(CGEventSource(stateID: .privateState))
        let software = try unwrap(CGEvent(mouseEventSource: privateSource, mouseType: .mouseMoved,
                                          mouseCursorPosition: point, mouseButton: .left))
        try check(!shield.shouldBlockShieldEvent(type: .mouseMoved, event: software),
                  "Shield blocked private-state software events")

        let hidSource = try unwrap(CGEventSource(stateID: .hidSystemState))
        let physicalMove = try unwrap(CGEvent(mouseEventSource: hidSource, mouseType: .mouseMoved,
                                              mouseCursorPosition: point, mouseButton: .left))
        markPhysical(physicalMove)
        try check(shield.shouldBlockShieldEvent(type: .mouseMoved, event: physicalMove),
                  "Shield allowed physical pointer events")

        let physicalKey = try unwrap(CGEvent(keyboardEventSource: hidSource, virtualKey: 0, keyDown: true))
        markPhysical(physicalKey)
        try check(shield.shouldBlockShieldEvent(type: .keyDown, event: physicalKey),
                  "Shield allowed physical key events")

        // System-defined subtype 8 carries brightness (2) and media (16) keys.
        for (keyType, name) in [(2, "brightness"), (16, "media")] {
            let event = try unwrap(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: 0, context: nil,
                                                      subtype: 8, data1: keyType << 16, data2: 0)?.cgEvent)
            markPhysical(event)
            try check(shield.shouldBlockShieldEvent(type: CGEventType(rawValue: 14)!, event: event),
                      "Shield allowed physical \(name) keys")
        }
        print("Display control smoke passed: remote input allowed, physical pointer, key, brightness, and media keys blocked")
    }

    private static func markPhysical(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setIntegerValueField(.eventSourceStateID, value: Int64(CGEventSourceStateID.hidSystemState.rawValue))
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw SmokeError.message("Could not create a test event") }
        return value
    }

    private static func check(_ result: Bool, _ message: String) throws {
        if !result { throw SmokeError.message(message) }
    }

    private enum SmokeError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value }
        }
    }
}
