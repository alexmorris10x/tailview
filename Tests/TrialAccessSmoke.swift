import Foundation

@main
struct TrialAccessSmoke {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(TrialAccessRules.duration)
        let trial = purchase(TrialAccessRules.trialProductID, at: start)
        let lifetime = purchase(TrialAccessRules.lifetimeProductID, at: start)
        let revokedTrial = purchase(TrialAccessRules.trialProductID, at: start, revoked: start.addingTimeInterval(100))
        let refundedLifetime = purchase(TrialAccessRules.lifetimeProductID, at: start, revoked: start.addingTimeInterval(100))

        try check(evaluate([], [], start) == .trialAvailable, "Fresh install must not automatically start a trial")
        try check(evaluate([trial], [trial], start) == .trialActive(expiresAt: end), "Explicit trial must last exactly seven days")
        try check(evaluate([trial], [trial], end.addingTimeInterval(-1)).allowsStreaming(at: end.addingTimeInterval(-1)), "Final second of trial must remain usable")
        try check(evaluate([trial], [trial], end) == .trialExpired, "Trial must expire exactly at the deadline")
        try check(!TrialAccessRules.State.trialActive(expiresAt: end).allowsStreaming(at: end), "A stale state must not permit reconnect after expiry")
        try check(evaluate([trial], [trial], end.addingTimeInterval(30 * 86_400)) == .trialExpired, "Restoring an expired trial must not reset it")
        try check(evaluate([], [trial], start.addingTimeInterval(86_400)) == .trialActive(expiresAt: end), "Locally verified entitlements must work offline without a history fetch")

        let restored = TrialAccessRules.Purchase(productID: TrialAccessRules.trialProductID,
                                                purchaseDate: end.addingTimeInterval(10),
                                                originalPurchaseDate: start, revocationDate: nil)
        try check(evaluate([restored], [restored], end.addingTimeInterval(10)) == .trialExpired, "Restore date must not replace original purchase date")
        let repeated = purchase(TrialAccessRules.trialProductID, at: end.addingTimeInterval(10))
        try check(evaluate([trial, repeated], [repeated], end.addingTimeInterval(10)) == .trialExpired, "Earliest purchase must win across repeated transactions")
        try check(evaluate([revokedTrial, repeated], [repeated], end.addingTimeInterval(10)) == .trialExpired, "Revocation and repurchase must not restart the trial")
        try check(evaluate([revokedTrial], [revokedTrial], start.addingTimeInterval(200)) == .revoked, "Revoked trial must stop access immediately")
        try check(evaluate([lifetime], [lifetime], end.addingTimeInterval(99_999_999)) == .lifetime, "Permanent unlock must not expire")
        try check(evaluate([refundedLifetime], [], start.addingTimeInterval(200)) == .revoked, "Refund must revoke permanent access")
        try check(evaluate([lifetime], [], start.addingTimeInterval(200)) == .revoked, "Historical purchase alone must not grant current access")
        try check(evaluate([refundedLifetime, trial], [trial], start.addingTimeInterval(200)) == .trialActive(expiresAt: end), "Refund must preserve independently valid trial time")
        try check(evaluate([revokedTrial, lifetime], [lifetime], end) == .lifetime, "Permanent purchase must take precedence over expired trial")
        try check(TrialAccessRules.evaluate(history: [], currentEntitlements: [], hasUnverifiedTransactions: true, now: start) == .verificationFailed, "Unverified transactions must not unlock access or restart a trial")
        try check(evaluate([trial], [trial], start.addingTimeInterval(-1)) == .verificationFailed, "A clock before the original purchase must not grant trial time")
        print("Trial access checks passed: explicit start, exact expiry, offline receipt, restore, earliest date, refunds, revocation, lifetime, verification")
    }

    private static func purchase(_ id: String, at date: Date, revoked: Date? = nil) -> TrialAccessRules.Purchase {
        .init(productID: id, purchaseDate: date, originalPurchaseDate: date, revocationDate: revoked)
    }

    private static func evaluate(_ history: [TrialAccessRules.Purchase], _ current: [TrialAccessRules.Purchase], _ now: Date) -> TrialAccessRules.State {
        TrialAccessRules.evaluate(history: history, currentEntitlements: current, now: now)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
