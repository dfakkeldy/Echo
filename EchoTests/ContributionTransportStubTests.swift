// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ContributionTransportStubTests {
    private let payload = PronunciationContributionPayload(
        term: "Cholmondeley", ipa: "\u{2C8}t\u{0283}\u{028C}mli", language: "en",
        voiceModelVersion: "kokoro-v1.0", confidence: 0.9)

    @Test func blocksWithoutConsent() {
        let transport = DeferredContributionTransport()
        let result = transport.send([payload], consent: .notDecided)
        #expect(result == .blockedNoConsent)
    }

    @Test func deferredEvenWithConsentBecauseNoLiveChannel() {
        let transport = DeferredContributionTransport()
        let consent = ContributionConsent(isOptedIn: true, decidedAt: Date())
        let result = transport.send([payload], consent: consent)
        // Live transport is intentionally not built — must NOT transmit.
        guard case .deferred = result else {
            Issue.record("expected .deferred, got \(result)")
            return
        }
    }
}
