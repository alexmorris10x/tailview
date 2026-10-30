import Foundation
import StoreKit
import StoreKitTest
import UIKit
import XCTest
@testable import TailViewIOS

/// These tests use Apple's local StoreKit signing and transaction service. They
/// never fabricate verified receipts or contact a production purchase account.
@MainActor
final class PurchaseAccessStoreKitTests: XCTestCase {
    override func tearDown() async throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TailView", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = false
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        try await session.setSimulatedError(nil, forAPI: .appStoreSync)
        try await super.tearDown()
    }

    func testExplicitTrialAndRestorationKeepOriginalDeadline() async throws {
        let session = try await makeSession()
        defer { session.clearTransactions() }
        let access = try await makeAccess()
        XCTAssertEqual(access.state, .trialAvailable)
        XCTAssertFalse(access.streamAllowed)
        XCTAssertTrue(session.allTransactions().isEmpty)

        await access.startTrial()
        try await eventually { access.expirationDate != nil }
        let deadline = try XCTUnwrap(access.expirationDate)
        XCTAssertTrue(access.streamAllowed)
        try await eventually { await self.hasEntitlement(TrialAccessRules.trialProductID) }

        let restored = PurchaseAccess()
        await restored.restore()
        try await eventually { restored.expirationDate == deadline }
        await restored.startTrial()
        XCTAssertEqual(restored.expirationDate, deadline)
        XCTAssertEqual(session.allTransactions().count, 1)
    }

    func testPermanentUnlockRestoresAndRefundRevokesRunningAccess() async throws {
        let session = try await makeSession()
        defer { session.clearTransactions() }
        let access = try await makeAccess()
        await access.buyLifetime()
        try await eventually { access.state == .lifetime }
        XCTAssertTrue(access.streamAllowed)
        try await eventually { await self.hasEntitlement(TrialAccessRules.lifetimeProductID) }

        let restored = PurchaseAccess()
        await restored.restore()
        try await eventually { restored.state == .lifetime }
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        // No explicit refresh: this checks the transaction update listener.
        try await eventually { !access.streamAllowed && !restored.streamAllowed }
        XCTAssertEqual(access.state, .revoked)
    }

    func testAskToBuyDoesNotGrantAccessUntilApproved() async throws {
        let session = try await makeSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let access = try await makeAccess()
        await access.buyLifetime()
        XCTAssertEqual(access.pendingProductID, TrialAccessRules.lifetimeProductID)
        XCTAssertFalse(access.streamAllowed)
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await eventually { access.state == .lifetime }
        XCTAssertNil(access.pendingProductID)
    }

    func testCancellationDoesNotGrantAccessOrLeaveBusyState() async throws {
        let session = try await makeSession()
        defer { session.clearTransactions() }
        let access = try await makeAccess()
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await access.buyLifetime()
        XCTAssertFalse(access.streamAllowed)
        XCTAssertFalse(access.isBusy)
        XCTAssertNil(access.pendingProductID)
        XCTAssertEqual(access.state, .trialAvailable)
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCTAssertNotNil(access.message)
    }

    func testDeclinedAskToBuyCanBeRecheckedAndRetried() async throws {
        let session = try await makeSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let access = try await makeAccess()
        await access.buyLifetime()
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.declineAskToBuyTransaction(identifier: pending.identifier)
        await access.restore()
        XCTAssertFalse(access.streamAllowed)
        XCTAssertFalse(access.purchaseInProgress)
        await access.buyLifetime()
        XCTAssertEqual(access.pendingProductID, TrialAccessRules.lifetimeProductID)
        XCTAssertFalse(access.streamAllowed)
        let retry = try XCTUnwrap(session.allTransactions().first {
            $0.identifier != pending.identifier && $0.state == .deferred
        })
        try session.approveAskToBuyTransaction(identifier: retry.identifier)
        try await eventually { access.state == .lifetime }
    }

    func testVerifiedAccessSurvivesUnavailableProductCatalog() async throws {
        let session = try await makeSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: TrialAccessRules.lifetimeProductID)
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let access = PurchaseAccess()
        await access.refresh()
        try await eventually { access.state == .lifetime && !access.productsLoading }
        await access.loadProducts()
        XCTAssertNotNil(access.productError)
        XCTAssertTrue(access.streamAllowed)
    }

    private func makeSession() async throws -> SKTestSession {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TailView", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // Local StoreKit mutations return before StoreKit 2's entitlement
        // snapshot catches up. Do not let a previous case leak into this one.
        try await eventually {
            for await _ in StoreKit.Transaction.all { return false }
            for await _ in StoreKit.Transaction.currentEntitlements { return false }
            return true
        }
        return session
    }

    private func makeAccess() async throws -> PurchaseAccess {
        // Product.purchase requires a foreground scene even when the local
        // StoreKit session suppresses purchase dialogs.
        try await eventually {
            UIApplication.shared.connectedScenes.contains { scene in
                guard let windowScene = scene as? UIWindowScene else { return false }
                return scene.activationState == .foregroundActive
                    && windowScene.windows.contains { $0.isKeyWindow && !$0.isHidden }
            }
        }
        // Allow Apple's local service to apply the new session before the app
        // makes its first StoreKit request. This checks the real catalog rather
        // than replacing purchases with a test double.
        var catalog: [Product] = []
        for _ in 0..<20 {
            catalog = try await Product.products(for: TrialAccessRules.productIDs)
            if Set(catalog.map(\.id)) == Set(TrialAccessRules.productIDs) { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard Set(catalog.map(\.id)) == Set(TrialAccessRules.productIDs) else {
            let returned = catalog.map { "\($0.id): \($0.type), \($0.price)" }.joined(separator: ", ")
            XCTFail("Local StoreKit catalog unavailable for \(Bundle.main.bundleIdentifier ?? "unknown"). Returned products: [\(returned)]")
            throw TestEnvironmentUnavailable()
        }
        let access = PurchaseAccess()
        await access.refresh()
        try await eventually { access.state != .loading && !access.productsLoading }
        await access.loadProducts()
        XCTAssertNotEqual(access.state, .developer, "Run the TailViewPurchases scheme so developer access is disabled")
        guard access.lifetimeProduct != nil, access.trialProduct != nil else {
            XCTFail("Local StoreKit catalog did not load. Trial loaded: \(access.trialProduct != nil); unlock loaded: \(access.lifetimeProduct != nil). \(access.productError ?? "No product error reported.") Ensure the TailViewPurchases Run action and its inherited Test environment use TailView.storekit.")
            throw TestEnvironmentUnavailable()
        }
        return access
    }

    private func hasEntitlement(_ productID: String) async -> Bool {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == productID, transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    private func eventually(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("StoreKit did not reach the expected state within five seconds", file: file, line: line)
        throw TestTimeout()
    }

    private struct TestTimeout: Error {}
    private struct TestEnvironmentUnavailable: Error {}
}
