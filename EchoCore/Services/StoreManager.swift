import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreManager: ProEntitlementProviding {
    static let proUnlockProductID = ProductIDs.lifetime

    private(set) var products: [Product] = []
    private(set) var proUnlockProduct: Product?
    private(set) var isPro = false
    private(set) var lastStoreError: String?

    @ObservationIgnored private var lifetimeOwned = false
    @ObservationIgnored private var foundersOwned = false
    @ObservationIgnored private var subscriptionActive = false
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Back-compat alias so existing views still compile until they move to `isPro`.
    var hasUnlockedPro: Bool { isPro }

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
            let requestedProducts = try await Product.products(for: ProductIDs.all)
            products = requestedProducts
            proUnlockProduct = requestedProducts.first { $0.id == ProductIDs.lifetime }
            lastStoreError = nil
        } catch {
            products = []
            proUnlockProduct = nil
            lastStoreError = error.localizedDescription
        }

        await refreshPurchasedProducts()
    }

    /// Generic purchase for any product (subscription, non-consumable, etc.).
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let txn = try checkVerified(verification)
            await updateProUnlockState(from: txn)
            await txn.finish()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
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

    /// True when the user can still get the 7-day free trial on the subscription group.
    func isEligibleForFreeTrial() async -> Bool {
        guard
            let sub = products.first(where: { $0.id == ProductIDs.yearly })?.subscription
        else { return false }
        return await sub.isEligibleForIntroOffer
    }

    // MARK: - Private

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
        var lifetime = false
        var founders = false
        for await result in Transaction.currentEntitlements {
            guard let txn = try? checkVerified(result), txn.revocationDate == nil
            else { continue }
            if txn.productID == ProductIDs.lifetime { lifetime = true }
            if txn.productID == ProductIDs.founders { founders = true }
        }
        lifetimeOwned = lifetime
        foundersOwned = founders
        subscriptionActive = await isSubscriptionActive()
        recomputeIsPro()
    }

    private func isSubscriptionActive() async -> Bool {
        guard
            let statuses = try? await Product.SubscriptionInfo.status(
                for: ProductIDs.subscriptionGroupID)
        else { return false }
        // Active if ANY status in the group is an access-granting state with a verified transaction.
        return statuses.contains { status in
            (try? checkVerified(status.transaction)) != nil
                && ProEntitlement.isActive(status.state)
        }
    }

    private func recomputeIsPro() {
        isPro = ProEntitlement.isPro(
            lifetimeOwned: lifetimeOwned, foundersOwned: foundersOwned,
            subscriptionActive: subscriptionActive)
    }

    private func updateProUnlockState(from transaction: Transaction) async {
        await refreshPurchasedProducts()
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
