// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct DeterministicDivergenceClassifierTests {
    private func window(expected: String, heard: String, confidence: Double = 1.0)
        -> DivergenceWindow
    {
        DivergenceWindow(
            blockID: "b", expectedText: expected, heardText: heard,
            expectedWordStart: 0, expectedWordEnd: 0, audioStart: 0, audioEnd: 1,
            confidence: confidence)
    }

    @Test func emptyHeardIsOmission() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "brown", heard: ""))
        #expect(r.issueType == .omission)
        #expect(r.suggestedIPA == nil)
    }

    @Test func lowConfidenceWins() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "fox", heard: "fix", confidence: 0.3))
        #expect(r.issueType == .lowConfidence)
    }

    @Test func properNounIsPronunciation() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "Colonel", heard: "kernel"))
        #expect(r.issueType == .pronunciation)
    }

    @Test func defaultIsSubstitution() async {
        let c = DeterministicDivergenceClassifier()
        let r = await c.classify(window(expected: "lazy", heard: "crazy"))
        #expect(r.issueType == .substitution)
    }
}
