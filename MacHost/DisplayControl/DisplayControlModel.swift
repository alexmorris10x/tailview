import AppKit
import ServiceManagement

/// Keeps the Mac's built-in display dark during a remote session without
/// sleeping or locking the Mac. Formerly the separate Display Control app.
@MainActor
final class DisplayControlModel: ObservableObject {
    @Published private(set) var isBlackoutActive = false
    @Published private(set) var isBlackoutSupported = false
    @Published private(set) var isBuiltInDisconnected = false
    @Published private(set) var isDisconnectSupported = false
    @Published private(set) var isRecoveryCountdownActive = false
    @Published private(set) var recoverySecondsRemaining = 0
    @Published private(set) var isInputShieldActive = false
    @Published private(set) var blocksLocalInputWhenBlackedOut = false
    @Published private(set) var launchAtLoginStatus = SMAppService.Status.notRegistered

    /// Called after the built-in display is disconnected or reconnected so
    /// screen capture can follow the new main display.
    var onDisplayConfigurationChange: (() -> Void)?

    private let backlightController = BacklightController()
    private let physicalDisplayController = PhysicalDisplayController()
    private let localInputController = LocalInputController()
    private let defaults = UserDefaults.standard
    private let blockLocalInputKey = "tailview.display.blockLocalInputWhenBlackedOut"
    private var terminationObserver: NSObjectProtocol?

    init() {
        physicalDisplayController.recoverIfNeeded()
        backlightController.recoverIfNeeded()
        physicalDisplayController.stateDidChange = { [weak self] in self?.refresh() }
        localInputController.stateDidChange = { [weak self] in self?.refresh() }
        localInputController.securityFailureHandler = { [weak self] reason in
            self?.failClosedAfterInputShieldFailure(reason)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreForTermination() }
        }
        refresh()
    }

    var canSafelyDisconnect: Bool { physicalDisplayController.canSafelyDisconnect }

    func toggleBlackout() {
        if backlightController.isBlackoutActive {
            do {
                try backlightController.restore()
                localInputController.stop()
            } catch {
                showError(title: "Couldn’t restore the backlight", message: error.localizedDescription)
            }
        } else {
            do {
                if blocksLocalInputWhenBlackedOut {
                    try localInputController.startShield()
                }
                do {
                    try backlightController.blackout()
                } catch {
                    localInputController.stop()
                    throw error
                }
            } catch {
                showError(title: "Couldn’t start protected blackout", message: error.localizedDescription)
            }
        }
        refresh()
    }

    func disconnectBuiltIn() {
        guard physicalDisplayController.canSafelyDisconnect else {
            showError(
                title: "Another display required",
                message: "Connect and use another display, such as an external monitor or a virtual display, first. TailView will not disconnect the Mac’s only active display."
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Disconnect the built-in display?"
        alert.informativeText = "This uses an undocumented macOS interface. TailView will share the remaining main display instead. The built-in display will reconnect automatically after 15 seconds unless you choose Keep Disconnected. A Mac restart is the emergency fallback."
        alert.addButton(withTitle: "Disconnect for 15 Seconds")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try physicalDisplayController.disconnectBuiltIn()
        } catch {
            showError(title: "Couldn’t disconnect the built-in display", message: error.localizedDescription)
        }
        refresh()
    }

    func keepDisconnected() {
        physicalDisplayController.keepDisconnected()
        refresh()
    }

    func reconnectBuiltIn() {
        do {
            try physicalDisplayController.reconnectBuiltIn()
        } catch {
            showError(title: "Couldn’t reconnect the built-in display", message: error.localizedDescription)
        }
        refresh()
    }

    func setBlocksLocalInputWhenBlackedOut(_ shouldEnable: Bool) {
        defaults.set(shouldEnable, forKey: blockLocalInputKey)

        if !shouldEnable {
            localInputController.stop()
        } else if backlightController.isBlackoutActive {
            do {
                try localInputController.startShield()
            } catch {
                defaults.set(false, forKey: blockLocalInputKey)
                failClosedAfterInputShieldFailure("The local-input shield could not be started while blackout was active: \(error.localizedDescription)")
                showError(title: "Couldn’t block local input", message: error.localizedDescription)
            }
        }
        refresh()
    }

    func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
            }
        } catch {
            showError(title: "Couldn’t update Login Items", message: error.localizedDescription)
        }
        refresh()
    }

    func refresh() {
        let wasDisconnected = isBuiltInDisconnected
        isBlackoutActive = backlightController.isBlackoutActive
        isBlackoutSupported = backlightController.isSupported
        isBuiltInDisconnected = physicalDisplayController.isBuiltInDisconnected
        isDisconnectSupported = physicalDisplayController.isSupported
        isRecoveryCountdownActive = physicalDisplayController.isRecoveryCountdownActive
        recoverySecondsRemaining = physicalDisplayController.recoverySecondsRemaining
        isInputShieldActive = localInputController.isShieldActive
        blocksLocalInputWhenBlackedOut = defaults.bool(forKey: blockLocalInputKey)
        launchAtLoginStatus = SMAppService.mainApp.status
        if wasDisconnected != isBuiltInDisconnected {
            onDisplayConfigurationChange?()
        }
    }

    private func restoreForTermination() {
        localInputController.stop()
        if physicalDisplayController.isBuiltInDisconnected {
            try? physicalDisplayController.reconnectBuiltIn()
        }
        if backlightController.isBlackoutActive {
            try? backlightController.restore()
        }
    }

    private func showError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func failClosedAfterInputShieldFailure(_ reason: String) {
        guard backlightController.isBlackoutActive else { return }

        try? backlightController.enforceBlackoutNow()
        if physicalDisplayController.canSafelyDisconnect {
            do {
                try physicalDisplayController.disconnectBuiltIn()
                physicalDisplayController.keepDisconnected()
            } catch {
                fputs("TailView fail-closed disconnect error: \(error.localizedDescription)\n", stderr)
            }
        }

        let lockPosted = SessionLockController.lockCurrentSession()
        fputs("TailView input shield failure: \(reason); lockPosted=\(lockPosted)\n", stderr)
        refresh()
    }
}
