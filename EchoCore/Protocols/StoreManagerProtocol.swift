import Foundation
import StoreKit

@MainActor protocol StoreManagerProtocol: AnyObject {
    var products: [Product] { get }
    var proUnlockProduct: Product? { get }
    var hasUnlockedPro: Bool { get }
    var lastStoreError: String? { get }

    func requestProducts() async
    func purchaseProUnlock() async throws
    func restorePurchases() async
    func recordStoreError(_ error: Error)
}
