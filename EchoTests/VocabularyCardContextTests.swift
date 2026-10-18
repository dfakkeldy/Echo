// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct VocabularyCardContextTests {
    @Test func decodesContextSentence() {
        let json = #"{"context":"The ephemeral moment passed."}"#
        #expect(
            VocabularyCardContext.sentence(fromMediaJSON: json) == "The ephemeral moment passed.")
    }

    @Test func returnsNilForMissingOrMalformed() {
        #expect(VocabularyCardContext.sentence(fromMediaJSON: nil) == nil)
        #expect(VocabularyCardContext.sentence(fromMediaJSON: "") == nil)
        #expect(VocabularyCardContext.sentence(fromMediaJSON: "not json") == nil)
        #expect(VocabularyCardContext.sentence(fromMediaJSON: #"{"other":"x"}"#) == nil)
    }
}
