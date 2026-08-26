// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// Export Echo's current deterministic generated study deck draft as an importable JSON deck.
struct GenerateDeckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deck",
        abstract: "Generate an importable study deck JSON from persisted source blocks.")

    @Option(help: "Path to an Echo SQLite database containing the book's source blocks.")
    var db: String
    @Option(name: .customLong("audiobook-id"), help: "Audiobook id in the database.")
    var audiobookID: String
    @Option(help: "Deck/book title to store in the exported file.")
    var title: String
    @Option(help: "Output .echo-deck.json path.")
    var out: String
    @Option(name: .customLong("max-cards"), help: "Maximum cards to generate.")
    var maxCards: Int = 8

    @MainActor func run() async throws {
        let database = try DatabaseService(databaseURL: URL(fileURLWithPath: db))
        let sources = try StudyDeckSourceBuilder(db: database.writer).sources(
            audiobookID: audiobookID,
            selection: .wholeBook
        )
        let draft = FixtureStudyDeckGenerator().generate(
            sources: sources,
            settings: StudyDeckGenerationSettings(maximumCardCount: maxCards)
        )
        try StudyDeckFileExporter.writeImportDeck(
            from: draft,
            audiobookID: audiobookID,
            deckName: title,
            to: URL(fileURLWithPath: out)
        )
        print("DECK_DONE \(draft.cards.count) cards")
    }
}
