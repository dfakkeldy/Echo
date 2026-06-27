// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct StoreEntitlementTests {
    // Echo Pro is granted by an active subscription, lifetime unlock, or Founders unlock.

    @Test func activeSubscriptionIsPro() {
        #expect(
            ProEntitlement.isPro(
                subscriptionActive: true,
                lifetimeOwned: false,
                foundersOwned: false
            )
        )
    }

    @Test func lifetimeOwnerIsPro() {
        #expect(
            ProEntitlement.isPro(
                subscriptionActive: false,
                lifetimeOwned: true,
                foundersOwned: false
            )
        )
    }

    @Test func foundersOwnerIsPro() {
        #expect(
            ProEntitlement.isPro(
                subscriptionActive: false,
                lifetimeOwned: false,
                foundersOwned: true
            )
        )
    }

    @Test func allEntitlementsOwnedIsPro() {
        #expect(
            ProEntitlement.isPro(
                subscriptionActive: true,
                lifetimeOwned: true,
                foundersOwned: true
            )
        )
    }

    @Test func nothingOwnedIsNotPro() {
        #expect(
            !ProEntitlement.isPro(
                subscriptionActive: false,
                lifetimeOwned: false,
                foundersOwned: false
            )
        )
    }
}
