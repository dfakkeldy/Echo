// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, dependency-free entitlement rules — unit-testable without StoreKit.
enum ProEntitlement {
    /// Pro is granted by an active subscription, the lifetime unlock, or the Founders unlock.
    static func isPro(
        subscriptionActive: Bool,
        lifetimeOwned: Bool,
        foundersOwned: Bool,
        paywallDisabled: Bool = false
    ) -> Bool {
        paywallDisabled || subscriptionActive || lifetimeOwned || foundersOwned
    }
}

enum StoreAccessPolicy {
    /// Temporary launch/beta bypass while App Store products are being configured.
    static let paywallDisabled = true
}

/// What gating code depends on — mockable in tests.
@MainActor
protocol ProEntitlementProviding {
    var isPro: Bool { get }
}
