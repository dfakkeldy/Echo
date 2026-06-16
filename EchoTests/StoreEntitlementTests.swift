// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit
import Testing

@testable import Echo

struct StoreEntitlementTests {
    @Test func lifetimeOwnerIsPro() {
        #expect(
            ProEntitlement.isPro(
                lifetimeOwned: true, foundersOwned: false, subscriptionActive: false))
    }

    @Test func foundersOwnerIsPro() {
        #expect(
            ProEntitlement.isPro(
                lifetimeOwned: false, foundersOwned: true, subscriptionActive: false))
    }

    @Test func activeSubscriberIsPro() {
        #expect(
            ProEntitlement.isPro(
                lifetimeOwned: false, foundersOwned: false, subscriptionActive: true))
    }

    @Test func nothingOwnedIsNotPro() {
        #expect(
            !ProEntitlement.isPro(
                lifetimeOwned: false, foundersOwned: false, subscriptionActive: false))
    }

    @Test func subscriptionActiveStates() {
        #expect(ProEntitlement.isActive(.subscribed))
        #expect(ProEntitlement.isActive(.inGracePeriod))
        #expect(ProEntitlement.isActive(.inBillingRetryPeriod))
        #expect(!ProEntitlement.isActive(.expired))
        #expect(!ProEntitlement.isActive(.revoked))
    }
}
