import CoreGraphics
import Darwin
import Foundation

final class PhysicalDisplayController {
    private typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private typealias GetDisplayList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private let disabledByUsKey = "tailview.display.builtInDisconnectedByTailView"
    private let defaults = UserDefaults.standard
    private var frameworkHandles: [UnsafeMutableRawPointer] = []
    private var configureDisplayEnabled: ConfigureDisplayEnabled?
    private var getDisplayList: GetDisplayList?
    private var safetyTimer: Timer?

    private(set) var isBuiltInDisconnected = false
    private(set) var isRecoveryCountdownActive = false
    private(set) var recoverySecondsRemaining = 0
    var stateDidChange: (() -> Void)?

    init() {
        for path in [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        ] {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                frameworkHandles.append(handle)
            }
        }

        for handle in frameworkHandles {
            if configureDisplayEnabled == nil, let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") {
                configureDisplayEnabled = unsafeBitCast(symbol, to: ConfigureDisplayEnabled.self)
            }
            if getDisplayList == nil, let symbol = dlsym(handle, "CGSGetDisplayList") {
                getDisplayList = unsafeBitCast(symbol, to: GetDisplayList.self)
            }
        }
    }

    deinit {
        safetyTimer?.invalidate()
        for handle in frameworkHandles {
            dlclose(handle)
        }
    }

    var isSupported: Bool {
        configureDisplayEnabled != nil && getDisplayList != nil
    }

    var canSafelyDisconnect: Bool {
        guard isSupported, builtInDisplayID(in: allDisplayIDs()) != nil else { return false }
        return activeDisplayIDs().contains(where: { CGDisplayIsBuiltin($0) == 0 })
    }

    func recoverIfNeeded() {
        guard defaults.bool(forKey: disabledByUsKey) else { return }
        try? reconnectBuiltIn()
    }

    func disconnectBuiltIn() throws {
        guard isSupported else {
            throw DisplayControlError.unavailable("Physical-display disconnect is unavailable on this version of macOS.")
        }
        guard activeDisplayIDs().contains(where: { CGDisplayIsBuiltin($0) == 0 }) else {
            throw DisplayControlError.unsafe("Connect another display, such as an external monitor or a virtual display, before disconnecting the built-in display.")
        }
        guard let displayID = builtInDisplayID(in: allDisplayIDs()) else {
            throw DisplayControlError.unavailable("The built-in display could not be found.")
        }

        defaults.set(true, forKey: disabledByUsKey)
        do {
            try configure(displayID: displayID, enabled: false)
        } catch {
            defaults.set(false, forKey: disabledByUsKey)
            throw error
        }
        isBuiltInDisconnected = true
        beginRecoveryCountdown()
    }

    func keepDisconnected() {
        guard isBuiltInDisconnected else { return }
        isRecoveryCountdownActive = false
        recoverySecondsRemaining = 0
        startSafetyMonitor()
        stateDidChange?()
    }

    func reconnectBuiltIn() throws {
        guard let displayID = builtInDisplayID(in: allDisplayIDs()) else {
            throw DisplayControlError.unavailable("The built-in display could not be found. Restart the Mac to restore its normal display configuration.")
        }

        try configure(displayID: displayID, enabled: true)
        safetyTimer?.invalidate()
        safetyTimer = nil
        defaults.set(false, forKey: disabledByUsKey)
        isBuiltInDisconnected = false
        isRecoveryCountdownActive = false
        recoverySecondsRemaining = 0
        stateDidChange?()
    }


    private func configure(displayID: CGDirectDisplayID, enabled: Bool) throws {
        guard let configureDisplayEnabled else {
            throw DisplayControlError.unavailable("Physical-display disconnect is unavailable on this version of macOS.")
        }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw DisplayControlError.operationFailed("Beginning display configuration", beginResult.rawValue)
        }

        let configureResult = configureDisplayEnabled(configuration, displayID, enabled)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayControlError.operationFailed("Changing physical-display state", configureResult.rawValue)
        }

        let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard completeResult == .success else {
            throw DisplayControlError.operationFailed("Completing display configuration", completeResult.rawValue)
        }
    }

    private func beginRecoveryCountdown() {
        safetyTimer?.invalidate()
        recoverySecondsRemaining = 15
        isRecoveryCountdownActive = true
        stateDidChange?()

        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            if !self.activeDisplayIDs().contains(where: { CGDisplayIsBuiltin($0) == 0 }) {
                try? self.reconnectBuiltIn()
                return
            }

            self.recoverySecondsRemaining -= 1
            if self.recoverySecondsRemaining <= 0 {
                try? self.reconnectBuiltIn()
            } else {
                self.stateDidChange?()
            }
        }
    }

    private func startSafetyMonitor() {
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isBuiltInDisconnected else { return }
            if !self.activeDisplayIDs().contains(where: { CGDisplayIsBuiltin($0) == 0 }) {
                try? self.reconnectBuiltIn()
            }
        }
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    private func allDisplayIDs() -> [CGDirectDisplayID] {
        guard let getDisplayList else { return activeDisplayIDs() }
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else { return activeDisplayIDs() }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard getDisplayList(count, &displays, &count) == .success else { return activeDisplayIDs() }
        return Array(displays.prefix(Int(count)))
    }

    private func builtInDisplayID(in displays: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        displays.first(where: { CGDisplayIsBuiltin($0) != 0 })
    }
}
