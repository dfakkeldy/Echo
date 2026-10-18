// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ContributionConsentTests {
    @Test func defaultsToNotOptedIn() {
        #expect(ContributionConsent.notDecided.isOptedIn == false)
        #expect(ContributionConsent.notDecided.decidedAt == nil)
    }

    @Test func gateBlocksWhenNotOptedIn() {
        #expect(ContributionConsentGate.allows(.notDecided) == false)
    }

    @Test func gateBlocksWhenExplicitlyDeclined() {
        let declined = ContributionConsent(isOptedIn: false, decidedAt: Date())
        #expect(ContributionConsentGate.allows(declined) == false)
    }

    @Test func gateAllowsOnlyWhenExplicitlyOptedIn() {
        let optedIn = ContributionConsent(isOptedIn: true, decidedAt: Date())
        #expect(ContributionConsentGate.allows(optedIn))
    }
}
