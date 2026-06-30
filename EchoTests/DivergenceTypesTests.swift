// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct DivergenceTypesTests {
    @Test func windowAndClassificationAreValueEqual() {
        let w1 = DivergenceWindow(
            blockID: "b", expectedText: "colonel", heardText: "kernel",
            expectedWordStart: 2, expectedWordEnd: 3, audioStart: 1.0, audioEnd: 2.0,
            confidence: 0.7)
        let w2 = DivergenceWindow(
            blockID: "b", expectedText: "colonel", heardText: "kernel",
            expectedWordStart: 2, expectedWordEnd: 3, audioStart: 1.0, audioEnd: 2.0,
            confidence: 0.7)
        #expect(w1 == w2)
        let c = DivergenceClassification(
            issueType: .substitution, suggestedSpokenForm: nil, suggestedIPA: nil, confidence: 0.8)
        #expect(c.issueType == .substitution)
    }
}
