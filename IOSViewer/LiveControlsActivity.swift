import ActivityKit
import UIKit

/// Keeps one lock-screen Live Activity in step with the connected Mac.
/// iOS lets an app start an activity only while it is in the foreground;
/// updates and ending work from the background.
final class LiveControlsActivity {
    private var activity: Activity<TailViewControlsAttributes>?
    private var lastState: TailViewControlsAttributes.ContentState?
    private var lastPush = Date.distantPast

    /// iOS keeps showing the last state after it suspends or ends TailView,
    /// so each push expires and the activity reads as not running unless the
    /// app keeps confirming it.
    private static let lifetime: TimeInterval = 90
    private static let confirmInterval: TimeInterval = 30

    init() {
        // An activity left by a previous run controls nothing.
        for stale in Activity<TailViewControlsAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(macName: String, state: TailViewControlsAttributes.ContentState) {
        // A stale activity is still live; a fresh update clears the stale state.
        if let activity, activity.activityState == .active || activity.activityState == .stale,
           activity.attributes.macName == macName {
            guard state != lastState || Date().timeIntervalSince(lastPush) >= Self.confirmInterval else { return }
            lastState = state
            lastPush = Date()
            Task { await activity.update(ActivityContent(state: state, staleDate: Self.staleDate())) }
            return
        }
        end()
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: TailViewControlsAttributes(macName: macName),
                                            content: ActivityContent(state: state, staleDate: Self.staleDate()))
            lastState = state
            lastPush = Date()
        } catch {
            #if DEBUG
            print("TailView could not start lock screen controls: \(error.localizedDescription)")
            #endif
        }
    }

    private static func staleDate() -> Date { Date().addingTimeInterval(lifetime) }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
