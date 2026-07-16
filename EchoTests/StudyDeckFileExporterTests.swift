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

    /// The portable-v2 fields are additive optionals, so `JSONEncoder` must omit
    /// them entirely from exporter output. An emitted `"formatVersion": null`
    /// (or any other v2 key) would change the on-disk legacy contract, and any
    /// non-null v2 key would trip `ValidatedDeckImport`'s marker check.
    @Test func exportedJSONOmitsPortableV2Keys() throws {
        let deck = StudyDeckFileExporter.importDeck(
            from: Self.fixtureDraft,
            audiobookID: "file:///Books/Fixture/",
            deckName: "Fixture"
        )
        let data = try JSONEncoder().encode(deck)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == ["deckName", "targetMediaID", "cards"])
    }

    /// The executable form of "legacy JSON behavior does not change": the
    /// exporter's own output must still classify as legacy, not portable.
    @Test func exportedJSONClassifiesAsLegacy() throws {
        let deck = StudyDeckFileExporter.importDeck(
            from: Self.fixtureDraft,
            audiobookID: "file:///Books/Fixture/",
            deckName: "Fixture"
        )
        let data = try JSONEncoder().encode(deck)

        guard case .legacy = try ValidatedDeckImport.decode(data) else {
            Issue.record("Expected exporter output to classify as legacy")
            return
        }
    }

    private static let fixtureDraft = GeneratedStudyDeckDraft(
        cards: [
            GeneratedStudyDeckCardDraft(
                id: "card-1",
                sourceBlockID: "epub-file:///Books/Fixture/-s1-b2",
                frontText: "Front",
                backText: "Back"
            )
        ],
        validSourceBlockIDs: ["epub-file:///Books/Fixture/-s1-b2"]
    )
}
