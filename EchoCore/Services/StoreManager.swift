// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreManager: ProEntitlementProviding {
    static let proUnlockProductID = ProductIDs.lifetime

    private(set) var products: [Product] = []
    private(set) var monthlyProduct: Product?
    private(set) var yearlyProduct: Product?
    private(set) var proUnlockProduct: Product?
    private(set) var foundersProduct: Product?
    private(set) var isPro = false
    private(set) var lastStoreError: String?

    @ObservationIgnored private var subscriptionActive = false
    @ObservationIgnored private var lifetimeOwned = false
    @ObservationIgnored private var foundersOwned = false
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptionStatusUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Back-compat alias so existing views still compile until they move to `isPro`.
    var hasUnlockedPro: Bool { isPro }

    init() {
        transactionUpdatesTask = Task { [weak self] in
            await self?.listenForTransactionUpdates()
        }
        subscriptionStatusUpdatesTask = Task { [weak self] in
            await self?.listenForSubscriptionStatusUpdates()
        }
        refreshTask = Task { [weak self] in
            await self?.refreshPurchasedProducts()
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
        subscriptionStatusUpdatesTask?.cancel()
        refreshTask?.cancel()
    }

    func requestProducts() async {
        do {
            let requestedProducts = try await Product.products(for: ProductIDs.all)
            products = requestedProducts
            monthlyProduct = requestedProducts.first { $0.id == ProductIDs.monthly }
            yearlyProduct = requestedProducts.first { $0.id == ProductIDs.yearly }
            proUnlockProduct = requestedProducts.first { $0.id == ProductIDs.lifetime }
            foundersProduct = requestedProducts.first { $0.id == ProductIDs.founders }
            lastStoreError = nil
        } catch {
            products = []
            monthlyProduct = nil
            yearlyProduct = nil
            proUnlockProduct = nil
            foundersProduct = nil
            lastStoreError = error.localizedDescription
        }

        await refreshPurchasedProducts()
    }

    /// Purchase any Echo Pro product: subscription, lifetime, or Founders.
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let txn = try checkVerified(verification)
            await updateProUnlockState()
            await txn.finish()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    /// Back-compat helper for older settings surfaces that still expect the lifetime unlock.
    func purchaseProUnlock() async throws {
        if proUnlockProduct == nil {
            await requestProducts()
        }

        guard let proUnlockProduct else { return }

        let result = try await proUnlockProduct.purchase()
        switch result {
        case .success(let verificationResult):
            let transaction = try checkVerified(verificationResult)
            await updateProUnlockState()
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

    // MARK: - Private

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            do {
                let transaction = try checkVerified(result)
                await updateProUnlockState()
                await transaction.finish()
            } catch {
                lastStoreError = error.localizedDescription
            }
        }
    }

    private func listenForSubscriptionStatusUpdates() async {
        for await _ in Product.SubscriptionInfo.Status.updates {
            await refreshPurchasedProducts()
        }
    }

    private func refreshPurchasedProducts() async {
        var subscriptionEntitled = false
        var lifetime = false
        var founders = false
        for await result in Transaction.currentEntitlements {
            guard let txn = try? checkVerified(result), txn.revocationDate == nil
            else { continue }
            if ProductIDs.subscriptionIDs.contains(txn.productID) { subscriptionEntitled = true }
            if txn.productID == ProductIDs.lifetime { lifetime = true }
            if txn.productID == ProductIDs.founders { founders = true }
        }
        let subscriptionStatusActive = await hasActiveSubscriptionStatus()
        subscriptionActive = subscriptionEntitled || subscriptionStatusActive
        lifetimeOwned = lifetime
        foundersOwned = founders
        recomputeIsPro()
    }

    private func recomputeIsPro() {
        isPro = ProEntitlement.isPro(
            subscriptionActive: subscriptionActive,
            lifetimeOwned: lifetimeOwned,
            foundersOwned: foundersOwned)
    }

    private func updateProUnlockState() async {
        await refreshPurchasedProducts()
    }

    private func hasActiveSubscriptionStatus() async -> Bool {
        guard let subscriptionGroupID else { return false }
        do {
            let statuses = try await Product.SubscriptionInfo.status(for: subscriptionGroupID)
            return statuses.contains { status in
                switch status.state {
                case .subscribed, .inGracePeriod, .inBillingRetryPeriod:
                    true
                case .expired, .revoked:
                    false
                default:
                    false
                }
            }
        } catch {
            lastStoreError = error.localizedDescription
            return false
        }
    }

    private var subscriptionGroupID: String? {
        products.compactMap { $0.subscription?.subscriptionGroupID }.first
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
