import CoreGraphics
import Darwin
import Foundation

enum DisplayControlError: LocalizedError {
    case unavailable(String)
    case operationFailed(String, Int32)
    case unsafe(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .unsafe(let message):
            return message
        case .operationFailed(let operation, let code):
            return "\(operation) failed (error \(code))."
        }
    }
}

final class BacklightController {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let savedBrightnessKey = "tailview.display.savedBuiltInBrightness"
    private let blackoutActiveKey = "tailview.display.blackoutWasActive"
    private let defaults = UserDefaults.standard
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getBrightnessFunction: GetBrightness?
    private let setBrightnessFunction: SetBrightness?
    private var enforcementTimer: Timer?

    private(set) var isBlackoutActive = false

    init() {
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW | RTLD_LOCAL
        )

        if let frameworkHandle {
            if let symbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness") {
                getBrightnessFunction = unsafeBitCast(symbol, to: GetBrightness.self)
            } else {
                getBrightnessFunction = nil
            }

            if let symbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") {
                setBrightnessFunction = unsafeBitCast(symbol, to: SetBrightness.self)
            } else {
                setBrightnessFunction = nil
            }
        } else {
            getBrightnessFunction = nil
            setBrightnessFunction = nil
        }
    }

    deinit {
        enforcementTimer?.invalidate()
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    var isSupported: Bool {
        getBrightnessFunction != nil && setBrightnessFunction != nil && builtInDisplayID() != nil
    }

    func recoverIfNeeded() {
        guard defaults.bool(forKey: blackoutActiveKey) else { return }
        try? restore()
    }

    func blackout() throws {
        guard let displayID = builtInDisplayID() else {
            throw DisplayControlError.unavailable("No active built-in display was found.")
        }

        let currentBrightness = try brightness(for: displayID)
        if currentBrightness > 0.01 {
            defaults.set(Double(currentBrightness), forKey: savedBrightnessKey)
        } else if defaults.object(forKey: savedBrightnessKey) == nil {
            defaults.set(0.5, forKey: savedBrightnessKey)
        }

        defaults.set(true, forKey: blackoutActiveKey)
        try setBrightness(0, for: displayID)
        isBlackoutActive = true
        startEnforcingBlackout()
    }

    func restore() throws {
        guard let displayID = builtInDisplayID() else {
            throw DisplayControlError.unavailable("The built-in display is not currently active.")
        }

        let saved = defaults.object(forKey: savedBrightnessKey) as? Double ?? 0.5
        let restored = Float(min(max(saved, 0.05), 1.0))
        try setBrightness(restored, for: displayID)
        enforcementTimer?.invalidate()
        enforcementTimer = nil
        isBlackoutActive = false
        defaults.set(false, forKey: blackoutActiveKey)
    }

    func currentBrightness() throws -> Float {
        guard let displayID = builtInDisplayID() else {
            throw DisplayControlError.unavailable("No active built-in display was found.")
        }
        return try brightness(for: displayID)
    }

    func enforceBlackoutNow() throws {
        guard isBlackoutActive else { return }
        guard let displayID = builtInDisplayID() else {
            throw DisplayControlError.unavailable("No active built-in display was found.")
        }
        try setBrightness(0, for: displayID)
    }


    private func startEnforcingBlackout() {
        enforcementTimer?.invalidate()
        enforcementTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let self, self.isBlackoutActive, let displayID = self.builtInDisplayID() else { return }
            guard let current = try? self.brightness(for: displayID), current > 0.001 else { return }
            try? self.setBrightness(0, for: displayID)
        }
    }

    private func brightness(for displayID: CGDirectDisplayID) throws -> Float {
        guard let getBrightnessFunction else {
            throw DisplayControlError.unavailable("Backlight control is unavailable on this version of macOS.")
        }

        var value: Float = 0
        let result = getBrightnessFunction(displayID, &value)
        guard result == 0 else {
            throw DisplayControlError.operationFailed("Reading display brightness", result)
        }
        return value
    }

    private func setBrightness(_ value: Float, for displayID: CGDirectDisplayID) throws {
        guard let setBrightnessFunction else {
            throw DisplayControlError.unavailable("Backlight control is unavailable on this version of macOS.")
        }

        let result = setBrightnessFunction(displayID, min(max(value, 0), 1))
        guard result == 0 else {
            throw DisplayControlError.operationFailed("Setting display brightness", result)
        }
    }

    private func builtInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }

        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
    }
}
