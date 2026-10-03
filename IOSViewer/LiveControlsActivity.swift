import ActivityKit
import UIKit

/// Keeps one lock-screen Live Activity in step with the connected Mac.
/// iOS lets an app start an activity only while it is in the foreground;
/// updates and ending work from the background.
final class LiveControlsActivity {
    private var activity: Activity<TailViewControlsAttributes>?
    private var lastState: TailViewControlsAttributes.ContentState?

    init() {
        // An activity left by a previous run controls nothing.
        for stale in Activity<TailViewControlsAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(macName: String, state: TailViewControlsAttributes.ContentState) {
        if let activity, activity.activityState == .active, activity.attributes.macName == macName {
            guard state != lastState else { return }
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        end()
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: TailViewControlsAttributes(macName: macName),
                                            content: ActivityContent(state: state, staleDate: nil))
            lastState = state
        } catch {
            #if DEBUG
            print("TailView could not start lock screen controls: \(error.localizedDescription)")
            #endif
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
