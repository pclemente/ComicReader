import Foundation
import StoreKit
import UIKit

@objc(CRPlusStoreStatus)
public enum CRPlusStoreStatus: Int {
    case idle
    case loading
    case ready
    case purchasing
    case purchasePending
    case purchaseCancelled
    case restoring
    case restored
    case failed
}

/// Main-actor state for one non-consumable entitlement. StoreKit restore
/// transactions can have new transaction IDs, so state is keyed by the
/// original transaction lineage. A verified revocation permanently wins over
/// older positive evidence for that lineage during this process.
struct CRPlusEntitlementLedger {
    struct SnapshotToken: Equatable {
        fileprivate let generation: UInt64
        fileprivate let eventRevision: UInt64
    }

    private(set) var activeOriginalIDs: Set<UInt64> = []
    private(set) var revokedOriginalIDs: Set<UInt64> = []
    private var snapshotGeneration: UInt64 = 0
    private var eventRevision: UInt64 = 0

    var isUnlocked: Bool {
        !activeOriginalIDs.isEmpty
    }

    mutating func beginSnapshot() -> SnapshotToken {
        snapshotGeneration &+= 1
        return SnapshotToken(generation: snapshotGeneration,
                             eventRevision: eventRevision)
    }

    /// Applies a verified purchase or positive transaction update immediately.
    /// Returns false when a later verified revocation already exists for the
    /// same lineage.
    @discardableResult
    mutating func recordVerifiedActive(originalID: UInt64) -> Bool {
        eventRevision &+= 1
        guard !revokedOriginalIDs.contains(originalID) else {
            activeOriginalIDs.remove(originalID)
            return false
        }
        activeOriginalIDs.insert(originalID)
        return true
    }

    mutating func recordVerifiedRevocation(originalID: UInt64) {
        eventRevision &+= 1
        revokedOriginalIDs.insert(originalID)
        activeOriginalIDs.remove(originalID)
    }

    /// Replaces the active ledger with a complete current-entitlements
    /// snapshot. A snapshot loses if a newer snapshot started or a verified
    /// purchase/update arrived while it was being enumerated.
    @discardableResult
    mutating func commitSnapshot(activeOriginalIDs snapshotActiveOriginalIDs: Set<UInt64>,
                                 revokedOriginalIDs snapshotRevokedOriginalIDs: Set<UInt64>,
                                 token: SnapshotToken) -> Bool {
        let canReplace = token.generation == snapshotGeneration &&
            token.eventRevision == eventRevision
        // Even a superseded snapshot can contain authoritative revocation
        // evidence. Apply it before deciding whether its positive list is fresh.
        for originalID in snapshotRevokedOriginalIDs.subtracting(revokedOriginalIDs) {
            recordVerifiedRevocation(originalID: originalID)
        }
        guard canReplace else { return false }
        activeOriginalIDs = snapshotActiveOriginalIDs.subtracting(revokedOriginalIDs)
        return true
    }
}

@objc(CRPlusStore)
@MainActor
public final class CRPlusStore: NSObject {
    @objc public static let sharedStore = CRPlusStore()
    @objc public static let productIdentifier = "com.pabloclementeperez.ComicFlow.plus"

    @objc public class var didChangeNotification: NSNotification.Name {
        NSNotification.Name("CRPlusStoreDidChangeNotification")
    }

    @objc public class var entitlementDidChangeNotification: NSNotification.Name {
        NSNotification.Name("CRPlusStoreEntitlementDidChangeNotification")
    }

    @objc public private(set) dynamic var isUnlocked = false
    @objc public private(set) dynamic var isBusy = false
    @objc public private(set) dynamic var displayPrice: String?
    @objc public private(set) dynamic var error: NSError?
    @objc public private(set) dynamic var status = CRPlusStoreStatus.idle

    private enum FailureCode: Int {
        case productUnavailable = 1
        case unexpectedProduct = 2
        case failedVerification = 3
        case purchaseDidNotUnlock = 4
        case operationInProgress = 5
        case unknownPurchaseResult = 6
    }

    private static let errorDomain = "com.pabloclementeperez.ComicReader.CRPlusStore"

    private var product: Product?
    private var transactionUpdatesTask: Task<Void, Never>?
    private var hasStarted = false
    private var entitlementLedger = CRPlusEntitlementLedger()

    override init() {
        super.init()
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    /// Starts product loading, entitlement verification, and the transaction listener.
    /// Call this once during application launch; repeated calls are harmless.
    @objc public func start() {
        startTransactionListenerIfNeeded()
        guard !isBusy else {
            return
        }
        if hasStarted, product != nil, status != .failed {
            return
        }

        hasStarted = true
        transition(to: .loading, busy: true, error: nil)
        Task { [weak self] in
            await self?.prepareStore()
        }
    }

    /// Reconciles locally available StoreKit entitlement state without showing
    /// authentication UI. Call when the app returns to the foreground so an
    /// account or entitlement change made while inactive is reflected.
    @objc public func refreshEntitlementStatus() {
        guard !isBusy else { return }
        startTransactionListenerIfNeeded()
        Task { [weak self] in
            guard let self, !self.isBusy else { return }
            do {
                try await self.refreshEntitlement()
            } catch {
                if !self.isBusy {
                    self.transition(to: .failed, busy: false, error: error as NSError)
                }
            }
        }
    }

    /// Attempts to buy ComicReader Plus. The completion runs on the main actor.
    /// A false result with no error means the customer cancelled or approval is pending;
    /// inspect `status` to distinguish those outcomes.
    @objc(purchaseWithCompletion:)
    public func purchase(completion: @escaping (Bool, NSError?) -> Void) {
        startTransactionListenerIfNeeded()
        guard !isBusy else {
            completion(false, failure(.operationInProgress,
                                      "Another App Store operation is already in progress."))
            return
        }

        // Capture the presenting scene while the purchase still has its UIKit
        // interaction context. StoreKit requires an explicit confirmation scene
        // for reliable UIKit purchases on current OS releases.
        let purchaseScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        transition(to: .purchasing, busy: true, error: nil)
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let product = try await self.loadProduct()
                let result: Product.PurchaseResult
                if #available(iOS 17.0, macCatalyst 17.0, *), let purchaseScene {
                    result = try await product.purchase(confirmIn: purchaseScene)
                } else {
                    result = try await product.purchase()
                }
                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        guard transaction.productID == Self.productIdentifier,
                              transaction.productType == .nonConsumable else {
                            throw self.failure(.unexpectedProduct,
                                               "The App Store returned an unexpected product.")
                        }
                        if transaction.revocationDate != nil {
                            self.entitlementLedger.recordVerifiedRevocation(originalID: transaction.originalID)
                            self.setUnlocked(self.entitlementLedger.isUnlocked)
                            await transaction.finish()
                            throw self.failure(.purchaseDidNotUnlock,
                                               "This purchase is no longer active.")
                        }
                        guard self.entitlementLedger.recordVerifiedActive(originalID: transaction.originalID) else {
                            await transaction.finish()
                            throw self.failure(.purchaseDidNotUnlock,
                                               "This purchase is no longer active.")
                        }
                        // Grant the verified purchase immediately. An older in-flight
                        // entitlement snapshot must not overwrite this newer evidence.
                        self.setUnlocked(self.entitlementLedger.isUnlocked)
                        await transaction.finish()
                        guard self.isUnlocked else {
                            throw self.failure(.purchaseDidNotUnlock,
                                               "The purchase completed but its entitlement is not active.")
                        }
                        self.transition(to: .ready, busy: false, error: nil)
                        completion(true, nil)

                    case .unverified(_, let verificationError):
                        throw self.failure(.failedVerification,
                                           "The App Store transaction could not be verified.",
                                           underlying: verificationError)
                    }

                case .pending:
                    self.transition(to: .purchasePending, busy: false, error: nil)
                    completion(false, nil)

                case .userCancelled:
                    self.transition(to: .purchaseCancelled, busy: false, error: nil)
                    completion(false, nil)

                @unknown default:
                    throw self.failure(.unknownPurchaseResult,
                                       "The App Store returned an unknown purchase result.")
                }
            } catch {
                let nsError = error as NSError
                self.transition(to: .failed, busy: false, error: nsError)
                completion(false, nsError)
            }
        }
    }

    /// Presents the App Store restore flow, then revalidates the current entitlement.
    @objc(restoreWithCompletion:)
    public func restore(completion: @escaping (Bool, NSError?) -> Void) {
        startTransactionListenerIfNeeded()
        guard !isBusy else {
            completion(false, failure(.operationInProgress,
                                      "Another App Store operation is already in progress."))
            return
        }

        transition(to: .restoring, busy: true, error: nil)
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await AppStore.sync()
                try await self.refreshEntitlement()
                self.transition(to: .restored, busy: false, error: nil)
                completion(self.isUnlocked, nil)
            } catch {
                let nsError = error as NSError
                self.transition(to: .failed, busy: false, error: nsError)
                completion(false, nsError)
            }
        }
    }

    private func prepareStore() async {
        var preparationError: Error?

        do {
            try await refreshEntitlement()
        } catch {
            preparationError = error
        }

        do {
            _ = try await loadProduct()
        } catch {
            if preparationError == nil {
                preparationError = error
            }
        }

        if let preparationError {
            transition(to: .failed, busy: false, error: preparationError as NSError)
        } else {
            transition(to: .ready, busy: false, error: nil)
        }
    }

    private func loadProduct() async throws -> Product {
        if let product {
            return product
        }

        let products = try await Product.products(for: [Self.productIdentifier])
        guard let product = products.first(where: { $0.id == Self.productIdentifier }) else {
            throw failure(.productUnavailable,
                          "ComicReader Plus is not available from the App Store.")
        }
        guard product.type == .nonConsumable else {
            throw failure(.unexpectedProduct,
                          "ComicReader Plus is not configured as a non-consumable purchase.")
        }

        self.product = product
        setDisplayPrice(product.displayPrice)
        return product
    }

    private func refreshEntitlement() async throws {
        let token = entitlementLedger.beginSnapshot()
        var snapshotActiveOriginalIDs: Set<UInt64> = []
        var snapshotRevokedOriginalIDs: Set<UInt64> = []
        var verificationFailure: Error?

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                guard transaction.productID == Self.productIdentifier else {
                    continue
                }
                guard transaction.productType == .nonConsumable else { continue }
                if transaction.revocationDate != nil {
                    snapshotRevokedOriginalIDs.insert(transaction.originalID)
                } else {
                    snapshotActiveOriginalIDs.insert(transaction.originalID)
                }

            case .unverified(let transaction, let error):
                if transaction.productID == Self.productIdentifier {
                    verificationFailure = error
                }
            }
        }

        // currentEntitlements is a complete snapshot: an empty result is
        // authoritative after launch, foreground reconciliation, or sync.
        // The token prevents an older in-flight snapshot from erasing a newer
        // verified purchase or transaction update.
        let committed = entitlementLedger.commitSnapshot(
            activeOriginalIDs: snapshotActiveOriginalIDs,
            revokedOriginalIDs: snapshotRevokedOriginalIDs,
            token: token
        )
        setUnlocked(entitlementLedger.isUnlocked)
        if committed, !entitlementLedger.isUnlocked, let verificationFailure {
            throw failure(.failedVerification,
                          "The ComicReader Plus entitlement could not be verified.",
                          underlying: verificationFailure)
        }
    }

    private func startTransactionListenerIfNeeded() {
        guard transactionUpdatesTask == nil else {
            return
        }

        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else {
                    return
                }
                await self.processTransactionUpdate(result)
            }
        }
    }

    private func processTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == Self.productIdentifier,
                  transaction.productType == .nonConsumable else {
                return
            }
            let wasRevoked = transaction.revocationDate != nil
            if wasRevoked {
                entitlementLedger.recordVerifiedRevocation(originalID: transaction.originalID)
            } else {
                entitlementLedger.recordVerifiedActive(originalID: transaction.originalID)
            }
            setUnlocked(entitlementLedger.isUnlocked)
            await transaction.finish()

            do {
                if wasRevoked {
                    // A different original transaction can be active after a
                    // refund followed by a real repurchase.
                    try await refreshEntitlement()
                }
                if !isBusy {
                    transition(to: .ready, busy: false, error: nil)
                }
            } catch {
                if !isBusy {
                    transition(to: .failed, busy: false, error: error as NSError)
                }
            }

        case .unverified(let transaction, let verificationError):
            guard transaction.productID == Self.productIdentifier, !isBusy else {
                return
            }
            transition(to: .failed,
                       busy: false,
                       error: failure(.failedVerification,
                                      "The App Store transaction could not be verified.",
                                      underlying: verificationError))
        }
    }

    private func setUnlocked(_ unlocked: Bool) {
        guard isUnlocked != unlocked else {
            return
        }

        isUnlocked = unlocked
        NotificationCenter.default.post(name: Self.entitlementDidChangeNotification, object: self)
        postDidChange()
    }

    private func setDisplayPrice(_ price: String?) {
        guard displayPrice != price else {
            return
        }

        displayPrice = price
        postDidChange()
    }

    private func transition(to status: CRPlusStoreStatus, busy: Bool, error: NSError?) {
        self.status = status
        isBusy = busy
        self.error = error
        postDidChange()
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func failure(_ code: FailureCode,
                         _ description: String,
                         underlying: Error? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let underlying {
            userInfo[NSUnderlyingErrorKey] = underlying
        }
        return NSError(domain: Self.errorDomain, code: code.rawValue, userInfo: userInfo)
    }
}
