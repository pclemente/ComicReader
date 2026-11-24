import Foundation
import StoreKitTest

/// StoreKit's purchase-error controls are Swift-only. Configure the session in
/// the same UI-test runner that owns the local purchase, and read it back.
@available(iOS 17.0, *)
@objc(CRUIStoreKitErrors)
public final class CRUIStoreKitErrors: NSObject {
    @objc(setCancelledPurchase:session:completion:)
    public static func setCancelledPurchase(_ enabled: Bool, session: SKTestSession,
                                     completion: @escaping (String?) -> Void) {
        Task {
            do {
                if enabled {
                    try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
                } else {
                    try await session.setSimulatedError(nil, forAPI: .purchase)
                }
                let actual = await session.simulatedError(forAPI: .purchase)
                switch (enabled, actual) {
                case (true, .some(.generic(.userCancelled))), (false, nil):
                    completion(nil)
                default:
                    completion("Apple's test store did not retain the requested purchase-error setting.")
                }
            } catch {
                completion(error.localizedDescription)
            }
        }
    }
}
