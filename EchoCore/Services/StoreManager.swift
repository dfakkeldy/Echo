import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreManager: StoreManagerProtocol {
    static let proUnlockProductID = "com.echo.pro.unlock"

    private(set) var products: [Product] = []
    private(set) var proUnlockProduct: Product?
    private(set) var hasUnlockedPro = false
    private(set) var lastStoreError: String?

    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        transactionUpdatesTask = Task { [weak self] in
            await self?.listenForTransactionUpdates()
        }
        refreshTask = Task { [weak self] in
            await self?.refreshPurchasedProducts()
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
        refreshTask?.cancel()
    }

    func requestProducts() async {
        do {
            let requestedProducts = try await Product.products(for: [Self.proUnlockProductID])
            products = requestedProducts
            proUnlockProduct = requestedProducts.first { $0.id == Self.proUnlockProductID }
            lastStoreError = nil
        } catch {
            products = []
            proUnlockProduct = nil
            lastStoreError = error.localizedDescription
        }

        await refreshPurchasedProducts()
    }

    func purchaseProUnlock() async throws {
        if proUnlockProduct == nil {
            await requestProducts()
        }

        guard let proUnlockProduct else { return }

        let result = try await proUnlockProduct.purchase()
        switch result {
        case .success(let verificationResult):
            let transaction = try checkVerified(verificationResult)
            await updateProUnlockState(from: transaction)
            await transaction.finish()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            lastStoreError = nil
        } catch {
            lastStoreError = error.localizedDescription
        }
        await refreshPurchasedProducts()
    }

    func recordStoreError(_ error: Error) {
        lastStoreError = error.localizedDescription
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            do {
                let transaction = try checkVerified(result)
                await updateProUnlockState(from: transaction)
                await transaction.finish()
            } catch {
                lastStoreError = error.localizedDescription
            }
        }
    }

    private func refreshPurchasedProducts() async {
        var isUnlocked = false

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result),
                  transaction.productID == Self.proUnlockProductID,
                  transaction.revocationDate == nil
            else { continue }

            isUnlocked = true
            break
        }

        hasUnlockedPro = isUnlocked
    }

    private func updateProUnlockState(from transaction: Transaction) async {
        guard transaction.productID == Self.proUnlockProductID else { return }
        hasUnlockedPro = transaction.revocationDate == nil
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified(_, let error):
            throw error
        }
    }
}
