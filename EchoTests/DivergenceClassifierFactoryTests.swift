// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor @Suite struct DivergenceClassifierFactoryTests {
    private func window() -> DivergenceWindow {
        DivergenceWindow(
            blockID: "b", expectedText: "lazy", heardText: "crazy",
            expectedWordStart: 0, expectedWordEnd: 0, audioStart: 0, audioEnd: 1, confidence: 1.0)
    }

    @Test func deterministicPreferenceAlwaysReturnsDeterministic() async {
        let c = DivergenceClassifierFactory.make(
            preference: "deterministic", availabilityIsAvailable: true)
        #expect(c is DeterministicDivergenceClassifier)
        // Still classifies.
        let r = await c.classify(window())
        #expect(r.issueType == .substitution)
    }

    @Test func autoButUnavailableFallsBackToDeterministic() async {
        let c = DivergenceClassifierFactory.make(
            preference: "auto", availabilityIsAvailable: false)
        #expect(c is DeterministicDivergenceClassifier)
    }

    @Test func unknownPreferenceFallsBackToDeterministic() async {
        let c = DivergenceClassifierFactory.make(
            preference: "garbage", availabilityIsAvailable: true)
        #expect(c is DeterministicDivergenceClassifier)
    }
}
