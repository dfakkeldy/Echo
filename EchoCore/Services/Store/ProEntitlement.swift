// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit

/// Pure, dependency-free entitlement rules — unit-testable without StoreKit.
enum ProEntitlement {
    static func isPro(lifetimeOwned: Bool, foundersOwned: Bool, subscriptionActive: Bool) -> Bool {
        lifetimeOwned || foundersOwned || subscriptionActive
    }

    /// A subscription state that should grant access (active, or Apple is still trying to bill).
    static func isActive(_ state: Product.SubscriptionInfo.RenewalState) -> Bool {
        switch state {
        case .subscribed, .inGracePeriod, .inBillingRetryPeriod: return true
        case .expired, .revoked: return false
        default: return false
        }
    }
}

/// What gating code depends on — mockable in tests.
@MainActor
protocol ProEntitlementProviding {
    var isPro: Bool { get }
}
