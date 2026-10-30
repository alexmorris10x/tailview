import Combine
import Foundation
import StoreKit

/// StoreKit owns the durable receipt and offline cache. No local preference can
/// grant access, reset a trial, or stand in for a verified transaction.
@MainActor
final class PurchaseAccess: ObservableObject {
    typealias AccessState = TrialAccessRules.State
    static let shared = PurchaseAccess()

    @Published private(set) var state: AccessState = .loading
    @Published private(set) var trialProduct: Product?
    @Published private(set) var lifetimeProduct: Product?
    @Published private(set) var productsLoading = false
    @Published private(set) var productError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var pendingProductID: String?
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false

    private var history: [TrialAccessRules.Purchase] = []
    private var entitlements: [TrialAccessRules.Purchase] = []
    private var hasUnverifiedTransactions = false
    private var hasLoadedEntitlements = false
    private var refreshGeneration = 0
    private var updateTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private let developerAccess: Bool

    var streamAllowed: Bool { state.allowsStreaming(at: Date()) }
    var expirationDate: Date? { state.expirationDate }
    var canStartTrial: Bool { state == .trialAvailable && trialProduct != nil && lifetimeProduct != nil }
    var purchaseInProgress: Bool { isBusy || pendingProductID != nil }

    var statusTitle: String {
        switch state {
        case .loading: return "Checking purchases"
        case .trialAvailable: return "Try TailView free for 7 days"
        case .trialActive: return "Your 7-day trial is active"
        case .trialExpired: return "Your free trial has ended"
        case .lifetime: return "TailView is unlocked"
        case .revoked: return "Purchase access is unavailable"
        case .verificationFailed: return "Purchase could not be verified"
        case .developer: return "Developer access"
        }
    }

    var statusDetail: String {
        switch state {
        case .loading:
            return "Your App Store purchases are being checked. Setup and pairing remain available."
        case .trialAvailable:
            return "Start when your Mac is ready. Enjoy screen viewing, control, Mac audio, and microphone for seven days."
        case .trialActive(let expiresAt):
            return "Full access until \(expiresAt.formatted(date: .abbreviated, time: .shortened)). No automatic charge."
        case .trialExpired:
            return "Screen viewing, control, and audio are paused. Your saved Macs and setup remain available. Unlock once to continue."
        case .lifetime:
            return "Screen viewing, control, and audio are permanently unlocked for this Apple Account."
        case .revoked:
            return "The App Store no longer reports an active purchase. Restore purchases or unlock TailView to continue."
        case .verificationFailed:
            return "TailView could not verify your App Store transaction. Connect to the internet and restore purchases."
        case .developer:
            return "This development build has full access. App Store builds require a trial or a purchase."
        }
    }

    init() {
        // This route does not exist in a Release binary, and never applies to
        // the production bundle even if it is built with DEBUG.
        #if DEBUG
        developerAccess = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
            && !ProcessInfo.processInfo.arguments.contains("-tailview-test-purchases")
        #else
        developerAccess = false
        #endif
        if developerAccess { state = .developer }

        updateTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .verified(let transaction):
                    guard TrialAccessRules.productIDs.contains(transaction.productID) else { continue }
                    self.pendingProductID = nil
                    self.applyVerifiedTransaction(transaction)
                    await transaction.finish()
                case .unverified(let transaction, _):
                    guard TrialAccessRules.productIDs.contains(transaction.productID) else { continue }
                    self.pendingProductID = nil
                    self.showMessage("The App Store transaction could not be verified. Try Restore Purchases.", error: true)
                    await self.refresh()
                }
            }
        }
        Task { [weak self] in
            await self?.refresh()
            await self?.loadProducts()
        }
    }

    deinit {
        updateTask?.cancel()
        expiryTask?.cancel()
    }

    /// Call before foreground reconnection. Date evaluation is synchronous;
    /// StoreKit refresh then picks up refunds and purchases from other devices.
    func setForeground(_ foreground: Bool) {
        reevaluate()
        if foreground {
            Task { [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var newHistory: [TrialAccessRules.Purchase] = []
        var newEntitlements: [TrialAccessRules.Purchase] = []
        var unverified = false
        for await result in StoreKit.Transaction.all {
            switch result {
            case .verified(let transaction):
                if let record = record(transaction) { newHistory.append(record) }
            case .unverified(let transaction, _):
                unverified = unverified || TrialAccessRules.productIDs.contains(transaction.productID)
            }
        }
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                if let record = record(transaction) { newEntitlements.append(record) }
            case .unverified(let transaction, _):
                unverified = unverified || TrialAccessRules.productIDs.contains(transaction.productID)
            }
        }
        guard generation == refreshGeneration else { return }
        history = newHistory
        entitlements = newEntitlements
        hasUnverifiedTransactions = unverified
        hasLoadedEntitlements = true
        reevaluate()
    }

    func loadProducts() async {
        guard !productsLoading else { return }
        productsLoading = true
        productError = nil
        defer { productsLoading = false }
        do {
            let products = try await Product.products(for: TrialAccessRules.productIDs)
            // Refuse a mistakenly priced or subscription-based trial.
            trialProduct = products.first {
                $0.id == TrialAccessRules.trialProductID && $0.type == .nonConsumable && $0.price == 0
            }
            lifetimeProduct = products.first {
                $0.id == TrialAccessRules.lifetimeProductID && $0.type == .nonConsumable
            }
            if trialProduct == nil || lifetimeProduct == nil {
                productError = "Some purchases are unavailable from the App Store. Try again later. Existing access is unaffected."
            }
        } catch {
            productError = "Could not load App Store prices. Check your connection and try again. Existing access is unaffected."
        }
    }

    func startTrial() async {
        guard !purchaseInProgress else { return }
        await refresh()
        guard state == .trialAvailable else {
            showMessage("A trial is available once per Apple Account. Restoring purchases does not restart it.", error: true)
            return
        }
        guard let trialProduct, lifetimeProduct != nil else {
            showMessage("Load the free trial and permanent unlock price from the App Store before starting. Try reloading prices.", error: true)
            return
        }
        await purchase(trialProduct)
    }

    func buyLifetime() async {
        guard !purchaseInProgress, state != .lifetime else { return }
        guard let lifetimeProduct else {
            showMessage("The unlock is unavailable from the App Store. Try reloading prices.", error: true)
            return
        }
        await purchase(lifetimeProduct)
    }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await refresh()
            // A declined Ask to Buy request has no entitlement update. An
            // explicit recheck must let the customer try again afterwards.
            pendingProductID = nil
            if streamAllowed {
                showMessage("Your purchases have been restored.")
            } else if state == .trialExpired {
                showMessage("Your trial was restored, but its seven days have ended. Restoring does not restart it.")
            } else {
                showMessage("No active purchase was found for this Apple Account.")
            }
        } catch {
            showMessage("Purchases could not be restored. Check your connection and App Store sign-in, then try again.", error: true)
        }
    }

    private func purchase(_ product: Product) async {
        guard !purchaseInProgress else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                switch result {
                case .verified(let transaction):
                    guard transaction.productID == product.id else {
                        showMessage("The App Store returned a different purchase. Restore purchases to check your access.", error: true)
                        return
                    }
                    applyVerifiedTransaction(transaction)
                    await transaction.finish()
                    if streamAllowed { showMessage(product.id == TrialAccessRules.trialProductID ? "Your seven-day trial has started. No automatic charge." : "TailView is permanently unlocked.") }
                    else { showMessage("Purchase received, but no active access was found. Try Restore Purchases.", error: true) }
                case .unverified:
                    showMessage("Your purchase could not be verified. Try Restore Purchases. You do not need to buy it again.", error: true)
                    await refresh()
                }
            case .pending:
                pendingProductID = product.id
                showMessage("Waiting for App Store approval. Access will update automatically when the purchase is approved.")
            case .userCancelled:
                showMessage("Cancelled. No new purchase was made.")
            @unknown default:
                showMessage("The App Store did not complete the purchase. Try Restore Purchases before trying again.", error: true)
            }
        } catch {
            showMessage("The purchase did not complete: \(error.localizedDescription)", error: true)
        }
    }

    private func record(_ transaction: StoreKit.Transaction) -> TrialAccessRules.Purchase? {
        guard TrialAccessRules.productIDs.contains(transaction.productID), transaction.productType == .nonConsumable else { return nil }
        return .init(productID: transaction.productID, purchaseDate: transaction.purchaseDate,
                     originalPurchaseDate: transaction.originalPurchaseDate,
                     revocationDate: transaction.revocationDate)
    }

    /// A verified purchase result or update is itself the current entitlement
    /// event. Deliver it before finishing; a separate StoreKit enumeration can
    /// still reflect the snapshot from before this transaction.
    private func applyVerifiedTransaction(_ transaction: StoreKit.Transaction) {
        guard let purchase = record(transaction) else { return }
        // A refresh begun before this event must not overwrite the new result.
        refreshGeneration += 1
        history.append(purchase)
        entitlements.removeAll { $0.productID == purchase.productID }
        if purchase.revocationDate == nil { entitlements.append(purchase) }
        hasLoadedEntitlements = true
        reevaluate()
    }

    private func reevaluate() {
        expiryTask?.cancel()
        expiryTask = nil
        if developerAccess { state = .developer; return }
        guard hasLoadedEntitlements else { return }
        state = TrialAccessRules.evaluate(history: history, currentEntitlements: entitlements,
                                         hasUnverifiedTransactions: hasUnverifiedTransactions, now: Date())
        guard let expiry = expirationDate else { return }
        // Remains active during a background audio session. If iOS suspends us,
        // setForeground and streamAllowed both enforce the same deadline.
        let wait = max(0.01, min(60, expiry.timeIntervalSinceNow))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }

    private func showMessage(_ value: String, error: Bool = false) {
        messageIsError = error
        message = value
    }
}
