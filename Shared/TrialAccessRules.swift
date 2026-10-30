import Foundation

/// Pure entitlement rules. Records enter here only after StoreKit verification.
enum TrialAccessRules {
    static let trialProductID = "com.10x.tailview.ios.trial7"
    static let lifetimeProductID = "com.10x.tailview.ios.lifetime"
    static let productIDs: Set<String> = [trialProductID, lifetimeProductID]
    static let duration: TimeInterval = 7 * 24 * 60 * 60

    struct Purchase: Equatable {
        let productID: String
        let purchaseDate: Date
        let originalPurchaseDate: Date
        let revocationDate: Date?

        var firstPurchaseDate: Date { min(purchaseDate, originalPurchaseDate) }
    }

    enum State: Equatable {
        case loading
        case trialAvailable
        case trialActive(expiresAt: Date)
        case trialExpired
        case lifetime
        case revoked
        case verificationFailed
        case developer

        var expirationDate: Date? {
            if case .trialActive(let expiresAt) = self { return expiresAt }
            return nil
        }

        func allowsStreaming(at now: Date) -> Bool {
            switch self {
            case .lifetime, .developer: return true
            case .trialActive(let expiresAt):
                return now >= expiresAt.addingTimeInterval(-TrialAccessRules.duration) && now < expiresAt
            default: return false
            }
        }
    }

    /// Current entitlements grant access; history prevents restores or repeat
    /// transactions from restarting the trial. Refunded purchases do not grant it.
    static func evaluate(history: [Purchase], currentEntitlements: [Purchase],
                         hasUnverifiedTransactions: Bool = false, now: Date) -> State {
        let active = currentEntitlements.filter { $0.revocationDate == nil }
        if active.contains(where: { $0.productID == lifetimeProductID }) { return .lifetime }

        let records = history + currentEntitlements
        let trials = records.filter { $0.productID == trialProductID }
        if let firstDate = trials.map(\.firstPurchaseDate).min() {
            let expiresAt = firstDate.addingTimeInterval(duration)
            if now < firstDate { return .verificationFailed }
            if now >= expiresAt { return .trialExpired }
            if active.contains(where: { $0.productID == trialProductID }) {
                return .trialActive(expiresAt: expiresAt)
            }
        }

        if hasUnverifiedTransactions { return .verificationFailed }
        if records.contains(where: { productIDs.contains($0.productID) }) { return .revoked }
        return .trialAvailable
    }
}
