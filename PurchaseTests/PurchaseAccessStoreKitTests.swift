import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import TailViewIOS

/// These tests use Apple's local StoreKit signing and transaction service. They
/// never fabricate verified receipts or contact a production purchase account.
@MainActor
final class PurchaseAccessStoreKitTests: XCTestCase {
    func testExplicitTrialAndRestorationKeepOriginalDeadline() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let access = try await makeAccess()
        XCTAssertEqual(access.state, .trialAvailable)
        XCTAssertFalse(access.streamAllowed)
        XCTAssertTrue(session.allTransactions().isEmpty)

        await access.startTrial()
        try await eventually { access.expirationDate != nil }
        let deadline = try XCTUnwrap(access.expirationDate)
        XCTAssertTrue(access.streamAllowed)

        let restored = PurchaseAccess()
        await restored.restore()
        try await eventually { restored.expirationDate == deadline }
        await restored.startTrial()
        XCTAssertEqual(restored.expirationDate, deadline)
        XCTAssertEqual(session.allTransactions().count, 1)
    }

    func testPermanentUnlockRestoresAndRefundRevokesRunningAccess() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let access = try await makeAccess()
        await access.buyLifetime()
        try await eventually { access.state == .lifetime }
        XCTAssertTrue(access.streamAllowed)

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
        let session = try makeSession()
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
        let session = try makeSession()
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
        let session = try makeSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let access = try await makeAccess()
        await access.buyLifetime()
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.declineAskToBuyTransaction(identifier: pending.identifier)
        await access.restore()
        XCTAssertFalse(access.streamAllowed)
        XCTAssertFalse(access.purchaseInProgress)
        session.askToBuyEnabled = false
        await access.buyLifetime()
        try await eventually { access.state == .lifetime }
    }

    func testVerifiedAccessSurvivesUnavailableProductCatalog() async throws {
        let session = try makeSession()
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

    private func makeSession() throws -> SKTestSession {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TailView", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    private func makeAccess() async throws -> PurchaseAccess {
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

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("StoreKit did not reach the expected state within five seconds", file: file, line: line)
        throw TestTimeout()
    }

    private struct TestTimeout: Error {}
    private struct TestEnvironmentUnavailable: Error {}
}
