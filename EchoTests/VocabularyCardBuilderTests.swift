// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct VocabularyCardBuilderTests {
    @Test func mapsWordAndAnchorsOntoFlashcard() {
        let card = VocabularyCardBuilder.make(
            id: "vc-1", audiobookID: "book-1", word: "ephemeral",
            contextSentence: "It was an ephemeral moment.", blockID: "s1-b3",
            audioStart: 12.5, audioEnd: 13.0, createdAt: "2026-06-27T00:00:00Z")
        #expect(card.id == "vc-1")
        #expect(card.audiobookID == "book-1")
        #expect(card.frontText == "ephemeral")
        #expect(card.backText == "")  // no stored definition (spec)
        #expect(card.cardType == StudyFlashcardType.vocabulary)
        #expect(card.mediaTimestamp == 12.5)
        #expect(card.endTimestamp == 13.0)
        #expect(card.sourceBlockID == "s1-b3")
        #expect(card.isEnabled)
        #expect(card.mediaJSON?.contains("ephemeral moment") == true)  // context in mediaJSON
    }

    @Test func toleratesMissingContextAndAnchors() {
        let card = VocabularyCardBuilder.make(
            id: "vc-2", audiobookID: "b", word: "word", contextSentence: nil,
            blockID: nil, audioStart: 0, audioEnd: nil, createdAt: "t")
        #expect(card.endTimestamp == nil)
        #expect(card.sourceBlockID == nil)
        #expect(card.mediaJSON == nil)
    }
}

@Suite struct WordSentenceContextTests {
    @Test func returnsTheContainingSentence() {
        let text = "First sentence here. The ephemeral moment passed! Third one."
        let wordRange = (text as NSString).range(of: "ephemeral")
        #expect(
            WordSentenceContext.sentence(containing: wordRange, in: text)
                == "The ephemeral moment passed!")
    }

    @Test func ignoresDecimalPunctuationInsideSentence() {
        let text = "The value is 3.14 today. Next sentence."
        let wordRange = (text as NSString).range(of: "value")
        #expect(
            WordSentenceContext.sentence(containing: wordRange, in: text)
                == "The value is 3.14 today.")
    }

    @Test func fallsBackToWholeTextWhenNoBoundary() {
        let text = "no terminal punctuation here"
        let wordRange = (text as NSString).range(of: "terminal")
        #expect(WordSentenceContext.sentence(containing: wordRange, in: text) == text)
    }
}
