import Foundation
import StoreKit
@testable import Echo

/// Configurable StoreManager for unit testing.
final class MockStoreManager: StoreManagerProtocol {
    var products: [Product] = []
    var proUnlockProduct: Product?
    var hasUnlockedPro: Bool = false
    var lastStoreError: String?

    var requestProductsCallCount = 0
    var purchaseProUnlockCallCount = 0
    var restorePurchasesCallCount = 0
    var recordStoreErrorCalls: [Error] = []

    func requestProducts() async {
        requestProductsCallCount += 1
    }

    func purchaseProUnlock() async throws {
        purchaseProUnlockCallCount += 1
    }

    func restorePurchases() async {
        restorePurchasesCallCount += 1
    }

    func recordStoreError(_ error: Error) {
        recordStoreErrorCalls.append(error)
        lastStoreError = error.localizedDescription
    }
}
