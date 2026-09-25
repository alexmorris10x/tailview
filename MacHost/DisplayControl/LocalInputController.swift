import ApplicationServices
import CoreGraphics
import Foundation

private func localInputEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<LocalInputController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handleTapEvent(type: type, event: event)
}

/// Filters physical keyboard, system-key, mouse, and trackpad events while
/// letting software-posted events through, including TailView's own remote control.
final class LocalInputController {
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shieldWatchdogTimer: Timer?
    private var hasReportedShieldFailure = false

    private(set) var isShieldActive = false
    private(set) var blockedHardwareEventCount = 0
    private(set) var allowedSoftwareEventCount = 0
    var stateDidChange: (() -> Void)?
    var securityFailureHandler: ((String) -> Void)?

    deinit {
        stop()
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func startShield() throws {
        guard eventTap == nil else { return }
        guard isAccessibilityTrusted else {
            requestAccessibilityPermission()
            throw DisplayControlError.unavailable(
                "Allow TailView Mac under System Settings → Privacy & Security → Accessibility, then try again."
            )
        }

        let mask = LocalInputController.filteredEventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: localInputEventTapCallback,
            userInfo: opaqueSelf
        ) else {
            throw DisplayControlError.unavailable(
                "macOS did not allow the input shield. Confirm TailView Mac has Accessibility permission and relaunch it."
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            throw DisplayControlError.unavailable("The local-input shield could not be started.")
        }

        blockedHardwareEventCount = 0
        allowedSoftwareEventCount = 0
        hasReportedShieldFailure = false
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isShieldActive = true
        startShieldWatchdog()
        stateDidChange?()
    }

    func stop() {
        shieldWatchdogTimer?.invalidate()
        shieldWatchdogTimer = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isShieldActive = false
        hasReportedShieldFailure = false
        stateDidChange?()
    }

    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if isShieldActive {
                reportShieldFailure("macOS disabled the local-input event tap (event type \(type.rawValue)).")
            }
            return nil
        }

        guard isShieldActive else {
            return Unmanaged.passUnretained(event)
        }

        guard shouldBlockShieldEvent(type: type, event: event) else {
            allowedSoftwareEventCount += 1
            return Unmanaged.passUnretained(event)
        }

        blockedHardwareEventCount += 1
        return nil
    }

    func shouldBlockShieldEvent(type _: CGEventType, event: CGEvent) -> Bool {
        Self.isPhysicalHardwareEvent(event)
    }

    private func startShieldWatchdog() {
        shieldWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isShieldActive, let eventTap = self.eventTap else { return }
            if CGEvent.tapIsEnabled(tap: eventTap) {
                self.hasReportedShieldFailure = false
                return
            }

            CGEvent.tapEnable(tap: eventTap, enable: true)
            self.reportShieldFailure("The local-input event tap became disabled outside its callback.")
        }
        shieldWatchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reportShieldFailure(_ reason: String) {
        guard !hasReportedShieldFailure else { return }
        hasReportedShieldFailure = true
        guard let securityFailureHandler else { return }
        DispatchQueue.main.async {
            securityFailureHandler(reason)
        }
    }

    static func isPhysicalHardwareEvent(_ event: CGEvent) -> Bool {
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let sourceState = event.getIntegerValueField(.eventSourceStateID)
        return sourcePID == 0 && sourceState == Int64(CGEventSourceStateID.hidSystemState.rawValue)
    }

    private static let filteredEventTypes: [CGEventType] = [
        .keyDown,
        .keyUp,
        .flagsChanged,
        systemDefinedEventType,
        .mouseMoved,
        .leftMouseDown,
        .leftMouseUp,
        .leftMouseDragged,
        .rightMouseDown,
        .rightMouseUp,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        .scrollWheel
    ]
}
