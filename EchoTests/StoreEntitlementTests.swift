// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct StoreEntitlementTests {
    // Echo Pro is a one-time, non-consumable unlock — there is no subscription path.
    // Pro is granted iff the user owns the lifetime unlock OR the Founders unlock.

    @Test func lifetimeOwnerIsPro() {
        #expect(ProEntitlement.isPro(lifetimeOwned: true, foundersOwned: false))
    }

    @Test func foundersOwnerIsPro() {
        #expect(ProEntitlement.isPro(lifetimeOwned: false, foundersOwned: true))
    }

    @Test func bothOwnedIsPro() {
        #expect(ProEntitlement.isPro(lifetimeOwned: true, foundersOwned: true))
    }

    @Test func nothingOwnedIsNotPro() {
        #expect(!ProEntitlement.isPro(lifetimeOwned: false, foundersOwned: false))
    }
}
