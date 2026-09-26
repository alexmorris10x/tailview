import AppKit
import ApplicationServices

/// Moves the frontmost app's focused window to part of its screen through
/// the Accessibility API, which TailView already uses for remote control.
enum WindowArranger {
    @MainActor
    static func arrange(_ layout: ControlCommand.WindowLayout) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let window = focusedWindow(of: app.processIdentifier),
              let frame = frame(of: window),
              let screen = screen(containing: frame) else { return }

        let visible = axRect(fromScreenRect: screen.visibleFrame)
        let half = (visible.width / 2).rounded(.down)
        let target: CGRect
        switch layout {
        case .leftHalf:
            target = CGRect(x: visible.minX, y: visible.minY, width: half, height: visible.height)
        case .rightHalf:
            target = CGRect(x: visible.maxX - half, y: visible.minY, width: half, height: visible.height)
        case .fill:
            target = visible
        }
        // Set the position again after resizing, since an app may adjust a
        // size it cannot fit at the original position.
        setPosition(target.origin, of: window)
        setSize(target.size, of: window)
        setPosition(target.origin, of: window)
    }

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func setPosition(_ point: CGPoint, of window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func setSize(_ size: CGSize, of window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    /// The screen holding the window's center, using Accessibility's
    /// top-left coordinates.
    @MainActor
    private static func screen(containing frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { axRect(fromScreenRect: $0.frame).contains(center) }
            ?? NSScreen.main
    }

    /// AppKit screens use a bottom-left origin; Accessibility uses the
    /// top-left corner of the primary screen.
    @MainActor
    private static func axRect(fromScreenRect rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.height
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
