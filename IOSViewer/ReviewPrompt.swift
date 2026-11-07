import Foundation

/// Asks for an App Store rating at most once per app version, when the third
/// remote session lasting two minutes or more ends. The caller picks the moment
/// (a session that just ended with the app in front) and never asks over the
/// purchase, trial or expired-access screens.
enum ReviewPrompt {
    static let minimumSession: TimeInterval = 120
    static let sessionsBeforeAsking = 3
    private static let countKey = "reviewPrompt.longSessions"
    private static let versionKey = "reviewPrompt.askedVersion"

    /// Records a finished session; true when this is the moment to ask.
    static func sessionEnded(lasting duration: TimeInterval, defaults: UserDefaults = .standard) -> Bool {
        guard duration >= minimumSession else { return false }
        let count = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)
        return count >= sessionsBeforeAsking && defaults.string(forKey: versionKey) != currentVersion
    }

    static func markAsked(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: versionKey)
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
