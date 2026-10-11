import Foundation
import StoreKitTest
import UIKit
import XCTest

@testable import ComicFlow

final class CRPlusEntitlementLedgerTests: XCTestCase {
    func testSupersededSnapshotStillAppliesVerifiedRevocation() {
        var ledger = CRPlusEntitlementLedger()
        ledger.recordVerifiedActive(originalID: 100)
        let olderSnapshot = ledger.beginSnapshot()
        let newerSnapshot = ledger.beginSnapshot()
        XCTAssertFalse(ledger.commitSnapshot(activeOriginalIDs: [],
                                             revokedOriginalIDs: [100],
                                             token: olderSnapshot))
        XCTAssertFalse(ledger.isUnlocked)
        XCTAssertFalse(ledger.commitSnapshot(activeOriginalIDs: [100],
                                             revokedOriginalIDs: [],
                                             token: newerSnapshot))
        XCTAssertFalse(ledger.isUnlocked)
    }

    func testSnapshotStartedBeforePurchaseCannotUndoVerifiedGrant() {
        var ledger = CRPlusEntitlementLedger()
        let staleSnapshot = ledger.beginSnapshot()

        XCTAssertTrue(ledger.recordVerifiedActive(originalID: 101))
        XCTAssertFalse(ledger.commitSnapshot(activeOriginalIDs: [],
                                             revokedOriginalIDs: [],
                                             token: staleSnapshot))
        XCTAssertTrue(ledger.isUnlocked)
        XCTAssertEqual(ledger.activeOriginalIDs, [101])
    }

    func testVerifiedRevocationDominatesStalePositiveForSameLineage() {
        var ledger = CRPlusEntitlementLedger()
        XCTAssertTrue(ledger.recordVerifiedActive(originalID: 202))
        ledger.recordVerifiedRevocation(originalID: 202)

        // Even a later snapshot containing an older positive transaction for
        // this lineage cannot revive a verified revocation.
        let snapshot = ledger.beginSnapshot()
        XCTAssertTrue(ledger.commitSnapshot(activeOriginalIDs: [202],
                                            revokedOriginalIDs: [],
                                            token: snapshot))
        XCTAssertFalse(ledger.recordVerifiedActive(originalID: 202))
        XCTAssertFalse(ledger.isUnlocked)
        XCTAssertEqual(ledger.revokedOriginalIDs, [202])
    }

    func testFreshAuthoritativeEmptySnapshotClearsPriorAccountEntitlement() {
        var ledger = CRPlusEntitlementLedger()
        XCTAssertTrue(ledger.recordVerifiedActive(originalID: 303))
        XCTAssertTrue(ledger.isUnlocked)

        let currentAccountSnapshot = ledger.beginSnapshot()
        XCTAssertTrue(ledger.commitSnapshot(activeOriginalIDs: [],
                                            revokedOriginalIDs: [],
                                            token: currentAccountSnapshot))
        XCTAssertFalse(ledger.isUnlocked)
        XCTAssertTrue(ledger.activeOriginalIDs.isEmpty)
    }

    func testRepurchaseUsesNewOriginalLineageAfterRefund() {
        var ledger = CRPlusEntitlementLedger()
        XCTAssertTrue(ledger.recordVerifiedActive(originalID: 404))
        ledger.recordVerifiedRevocation(originalID: 404)

        XCTAssertTrue(ledger.recordVerifiedActive(originalID: 405))
        XCTAssertTrue(ledger.isUnlocked)
        XCTAssertEqual(ledger.activeOriginalIDs, [405])
        XCTAssertEqual(ledger.revokedOriginalIDs, [404])
    }
}

@MainActor
final class CRPlusStoreTests: XCTestCase {
    private enum TestFailure: Error {
        case timedOut
    }

    private let productIdentifier = "com.pabloclementeperez.ComicFlow.plus"

    func testPurchaseRestoreAndRefundLifecycle() async throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This Xcode toolchain links a native macOS StoreKitTest framework into the hosted Mac Catalyst test. Purchases complete, but currentEntitlements and refund updates are not delivered to the Catalyst process. The deterministic ledger tests run here; this integration lifecycle remains enabled on iOS.")
#endif
        logStage("session setup started")
        guard let configurationURL = Bundle(for: Self.self).url(forResource: "ComicReader",
                                                                 withExtension: "storekit") else {
            XCTFail("ComicReader.storekit is missing from the unit test bundle")
            return
        }
        let session = try SKTestSession(contentsOf: configurationURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        logStage("session setup finished")
        defer {
            logStage("session cleanup started")
            session.clearTransactions()
            logStage("session cleanup finished")
        }

        // Create the listener and load products only after the test session exists.
        // The application singleton has already started by hosted-test launch.
        let store = CRPlusStore()
        logStage("store readiness started", store: store)
        store.start()
        try await waitUntil("the initial StoreKit request did not finish") {
            !store.isBusy
        }
        if store.displayPrice == nil {
            store.start()
        }
        try await waitUntil("the store did not become ready") {
            !store.isBusy && store.displayPrice?.isEmpty == false
        }
        logStage("store readiness finished", store: store)
        XCTAssertFalse(store.isUnlocked)
        XCTAssertNotNil(store.displayPrice)

        try await waitUntil("the hosted app did not expose an active purchase scene",
                            timeout: 10) {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .contains { scene in
                    scene.activationState == .foregroundActive &&
                        scene.windows.contains { $0.isKeyWindow && !$0.isHidden }
                }
        }
        logStage("purchase started", store: store)
        let purchased = try await purchase(using: store)
        logStage("purchase finished", store: store)
        XCTAssertTrue(purchased)
        XCTAssertTrue(store.isUnlocked)
        XCTAssertEqual(store.status, .ready)

        logStage("restore started", store: store)
        let restored = try await restore(using: store)
        logStage("restore finished", store: store)
        XCTAssertTrue(restored)
        XCTAssertTrue(store.isUnlocked)
        XCTAssertEqual(store.status, .restored)

        logStage("refund started", store: store)
        guard let transaction = session.allTransactions().first(where: {
            $0.productIdentifier == productIdentifier
        }) else {
            XCTFail("StoreKit Test did not record the ComicReader Plus transaction")
            return
        }
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitUntil("a refunded purchase remained unlocked") {
            !store.isUnlocked && store.status == .ready
        }
        logStage("refund finished", store: store)
        XCTAssertFalse(store.isUnlocked)
        XCTAssertEqual(store.status, .ready)
        logStage("lifecycle finished", store: store)
    }

    private func purchase(using store: CRPlusStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.purchase { unlocked, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: unlocked)
                }
            }
        }
    }

    private func restore(using store: CRPlusStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.restore { unlocked, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: unlocked)
                }
            }
        }
    }

    private func waitUntil(_ failureMessage: String,
                           timeout: TimeInterval = 8,
                           condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard condition() else {
            XCTFail(failureMessage)
            throw TestFailure.timedOut
        }
    }

    private func logStage(_ stage: String, store: CRPlusStore? = nil) {
        var message = "[CRPlusStoreTests] \(stage)"
        if let store {
            message += " status=\(store.status.rawValue) busy=\(store.isBusy) unlocked=\(store.isUnlocked) price=\(store.displayPrice ?? "nil")"
        }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
