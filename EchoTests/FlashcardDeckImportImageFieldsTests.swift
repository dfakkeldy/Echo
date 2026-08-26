// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct FlashcardDeckImportImageFieldsTests {
    @Test func decodesImageAnchorAndImageFileWhenPresent() throws {
        let json = """
            {"deckName":"D","targetMediaID":"m","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly","imageAnchor":"s4-b3"},
              {"frontText":"Q2","backText":"A2","triggerTiming":"manualOnly","imageFile":"images/x.png"}]}
            """
        let deck = try JSONDecoder().decode(FlashcardDeckImport.self, from: Data(json.utf8))
        #expect(deck.cards[0].imageAnchor == "s4-b3")
        #expect(deck.cards[0].imageFile == nil)
        #expect(deck.cards[1].imageFile == "images/x.png")
        #expect(deck.cards[1].imageAnchor == nil)
    }

    @Test func absentImageFieldsDecodeAsNil() throws {
        let json = """
            {"deckName":"D","targetMediaID":"m","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly"}]}
            """
        let deck = try JSONDecoder().decode(FlashcardDeckImport.self, from: Data(json.utf8))
        #expect(deck.cards[0].imageAnchor == nil)
        #expect(deck.cards[0].imageFile == nil)
    }
}
