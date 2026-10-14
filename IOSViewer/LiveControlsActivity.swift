import ActivityKit
import UIKit

/// Keeps one lock-screen Live Activity in step with the connected Mac.
/// iOS lets an app start an activity only while it is in the foreground;
/// updates and ending work from the background.
final class LiveControlsActivity {
    private var activity: Activity<TailViewControlsAttributes>?
    private var lastState: TailViewControlsAttributes.ContentState?
    private var lastExpires = true
    private var lastPush = Date.distantPast
    private var repush: DispatchWorkItem?

    /// iOS keeps showing the last state after it suspends or ends TailView,
    /// so each push expires and the activity reads as not running unless the
    /// app keeps confirming it.
    private static let lifetime: TimeInterval = 90
    private static let confirmInterval: TimeInterval = 30
    /// A change is sent once more after this, so a copy that missed it, such
    /// as the one macOS mirrors in the Mac's menu bar, catches up.
    private static let repushDelay: TimeInterval = 3

    init() {
        // An activity left by a previous run controls nothing. When iOS
        // launches TailView in the background for a tap on one, keep it so
        // the tap can show the pause; with no tap the first refresh ends it.
        let left = Activity<TailViewControlsAttributes>.activities
        let kept = UIApplication.shared.applicationState == .background ? left.first : nil
        activity = kept
        for stale in left where stale.id != kept?.id {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The Mac and state the lock screen shows, if anything.
    var shown: (macName: String, state: TailViewControlsAttributes.ContentState)? {
        guard let activity else { return nil }
        return (activity.attributes.macName, lastState ?? activity.content.state)
    }

    /// `expires: false` is for a state that stays true while iOS suspends
    /// TailView, such as a pause that waits for the app to open. `sent` runs
    /// on the main queue once the update is delivered, or at once if none is.
    func update(macName: String, state: TailViewControlsAttributes.ContentState, expires: Bool = true,
                sent: (() -> Void)? = nil) {
        // A stale activity is still live; a fresh update clears the stale state.
        if let activity, activity.activityState == .active || activity.activityState == .stale,
           activity.attributes.macName == macName {
            let changed = state != lastState
            guard changed || Date().timeIntervalSince(lastPush) >= Self.confirmInterval else {
                sent?()
                return
            }
            push(state, expires: expires, to: activity, sent: sent)
            if changed { scheduleRepush() }
            return
        }
        defer { sent?() }
        // Only a foreground app may start one, and the watchdog asks every
        // second in the background.
        guard UIApplication.shared.applicationState == .active else { return }
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: TailViewControlsAttributes(macName: macName),
                                            content: ActivityContent(state: state,
                                                                     staleDate: expires ? Self.staleDate() : nil))
            lastState = state
            lastExpires = expires
            lastPush = Date()
            scheduleRepush()
        } catch {
            #if DEBUG
            print("TailView could not start lock screen controls: \(error.localizedDescription)")
            #endif
        }
    }

    private func push(_ state: TailViewControlsAttributes.ContentState, expires: Bool,
                      to activity: Activity<TailViewControlsAttributes>, sent: (() -> Void)?) {
        lastState = state
        lastExpires = expires
        lastPush = Date()
        let content = ActivityContent(state: state, staleDate: expires ? Self.staleDate() : nil)
        Task {
            await activity.update(content)
            if let sent { DispatchQueue.main.async { sent() } }
        }
    }

    /// Sends the latest state once more shortly after a change, even inside
    /// the confirm interval. On 15 Oct the Mac's menu bar kept an orange Mic
    /// after the iPhone's microphone had started.
    private func scheduleRepush() {
        repush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let activity = self.activity, let state = self.lastState,
                  activity.activityState == .active || activity.activityState == .stale else { return }
            self.push(state, expires: self.lastExpires, to: activity, sent: nil)
        }
        repush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.repushDelay, execute: work)
    }

    private static func staleDate() -> Date { Date().addingTimeInterval(lifetime) }

    /// `sent` runs on the main queue once the activity has ended, or at once
    /// if there is none.
    func end(sent: (() -> Void)? = nil) {
        repush?.cancel()
        repush = nil
        guard let activity else {
            sent?()
            return
        }
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            if let sent { DispatchQueue.main.async { sent() } }
        }
    }
}
