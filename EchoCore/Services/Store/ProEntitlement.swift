// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, dependency-free entitlement rules — unit-testable without StoreKit.
enum ProEntitlement {
    /// Echo Pro is a one-time, non-consumable unlock — there is no subscription path.
    /// Pro is granted iff the user owns the lifetime unlock OR the Founders unlock
    /// (or the temporary launch bypass is active).
    static func isPro(
        lifetimeOwned: Bool,
        foundersOwned: Bool,
        paywallDisabled: Bool = false
    ) -> Bool {
        paywallDisabled || lifetimeOwned || foundersOwned
    }
}

enum StoreAccessPolicy {
    /// The approved paid candidate requires verified one-time ownership.
    static let paywallDisabled = false
}

/// What gating code depends on — mockable in tests.
@MainActor
protocol ProEntitlementProviding {
    var isPro: Bool { get }
}
