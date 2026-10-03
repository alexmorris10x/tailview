import ActivityKit
import AppIntents

/// The lock-screen and Dynamic Island controls for a connected Mac. Built
/// into both the app and the widget extension: the extension draws the
/// activity, and its buttons run these intents in the app's process.
struct TailViewControlsAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var microphoneOn: Bool
        /// Unmuted but nothing is being sent, as in the app's orange Mic.
        var microphoneNeedsAttention: Bool
        var macSoundOn: Bool
        var functionHeld: Bool
        var controlAvailable: Bool
    }

    var macName: String
}

enum LiveControlAction {
    case microphone, macSound, function
}

enum LiveControls {
    /// Set by the app on the main thread and called there. The widget
    /// extension never runs these intents.
    static var handler: ((LiveControlAction) -> Void)?

    static func perform(_ action: LiveControlAction) async {
        await MainActor.run { handler?(action) }
    }
}

struct ToggleMicrophoneIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mute or Unmute Microphone"
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        await LiveControls.perform(.microphone)
        return .result()
    }
}

struct ToggleMacSoundIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mute or Unmute Mac Sound"
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        await LiveControls.perform(.macSound)
        return .result()
    }
}

/// Buttons on the lock screen can only be tapped, so fn latches: one tap
/// holds the Mac's Fn key, the next releases it.
struct ToggleFunctionHoldIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Hold or Release Fn"
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        await LiveControls.perform(.function)
        return .result()
    }
}
