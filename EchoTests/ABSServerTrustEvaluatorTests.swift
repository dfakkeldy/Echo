// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ABSServerTrustEvaluatorTests {
    private func evaluator(pinned: String?) -> ABSServerTrustEvaluator {
        ABSServerTrustEvaluator(expectedHost: "homelab.local", pinnedSHA256: pinned)
    }

    @Test func caTrustedOnOurHostUsesDefault() {
        let d = evaluator(pinned: nil).decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: true, leafSHA256: "abc")
        #expect(d == .useDefault)
    }

    @Test func untrustedOurHostNoPinRejects() {
        let d = evaluator(pinned: nil).decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .reject)
    }

    @Test func untrustedOurHostMatchingPinAccepts() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .accept)
    }

    @Test func untrustedOurHostMismatchedPinRejects() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "different")
        #expect(d == .reject)
    }

    @Test func differentHostUsesDefaultEvenWithPin() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "cdn.example.com",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .useDefault)
    }

    @Test func nonServerTrustMethodUsesDefault() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: false, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .useDefault)
    }

    @Test func hostComparisonIsCaseInsensitive() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "Homelab.LOCAL",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .accept)
    }

    @Test func untrustedOurHostPinSetButNilLeafRejects() {
        let d = evaluator(pinned: "abc").decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: nil)
        #expect(d == .reject)
    }

    @Test func mixedCaseExpectedHostStillMatches() {
        let e = ABSServerTrustEvaluator(expectedHost: "Homelab.LOCAL", pinnedSHA256: "abc")
        let d = e.decide(
            isServerTrust: true, challengeHost: "homelab.local",
            defaultTrustSucceeded: false, leafSHA256: "abc")
        #expect(d == .accept)
    }
}
