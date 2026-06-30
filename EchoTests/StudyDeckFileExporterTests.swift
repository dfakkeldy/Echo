// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct StudyDeckFileExporterTests {
    @Test func exportUsesPortableSourceAnchorsAndManualTiming() throws {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "card-1",
                    sourceBlockID: "epub-file:///Books/Fixture/-s1-b2",
                    frontText: "What key idea appears here?",
                    backText: "Keywords: fixture, memory."
                )
            ],
            validSourceBlockIDs: ["epub-file:///Books/Fixture/-s1-b2"]
        )

        let deck = StudyDeckFileExporter.importDeck(
            from: draft,
            audiobookID: "file:///Books/Fixture/",
            deckName: "Fixture"
        )

        let card = try #require(deck.cards.first)
        #expect(deck.deckName == "Fixture")
        #expect(deck.targetMediaID == "file:///Books/Fixture/")
        #expect(card.frontText == "What key idea appears here?")
        #expect(card.backText == "Keywords: fixture, memory.")
        #expect(card.sourceAnchor == "s1-b2")
        #expect(card.triggerTiming == FlashcardTriggerTiming.manualOnly.rawValue)
        #expect(card.startTime == nil)
        #expect(card.endTime == nil)
    }

    @Test func writeEncodesImportableDeckJSON() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "echo-deck-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "card-1",
                    sourceBlockID: "source-1",
                    frontText: "Front",
                    backText: "Back"
                )
            ],
            validSourceBlockIDs: ["source-1"]
        )
        let url = folder.appending(path: "fixture.echo-deck.json")

        try StudyDeckFileExporter.writeImportDeck(
            from: draft,
            audiobookID: "book-1",
            deckName: "Fixture",
            to: url
        )

        let decoded = try JSONDecoder().decode(
            FlashcardDeckImport.self,
            from: Data(contentsOf: url)
        )
        #expect(decoded.deckName == "Fixture")
        #expect(decoded.cards.count == 1)
    }
}
