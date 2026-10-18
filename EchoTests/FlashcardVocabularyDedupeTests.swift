// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct FlashcardVocabularyDedupeTests {
    private func makeDB() throws -> DatabaseService { try DatabaseService(inMemory: ()) }

    /// Seeds the parent `audiobook` row required by the flashcard FK.
    private func seedAudiobook(id: String, in service: DatabaseService) throws {
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, 'Test', 3600, '2026-01-01T00:00:00Z')
                    """,
                arguments: [id])
        }
    }

    @Test func findsExistingVocabularyCardCaseInsensitively() throws {
        let db = try makeDB()
        try seedAudiobook(id: "book-1", in: db)
        let dao = FlashcardDAO(db: db.writer)
        let card = VocabularyCardBuilder.make(
            id: "vc-1", audiobookID: "book-1", word: "Ephemeral", contextSentence: nil,
            blockID: nil, audioStart: 1, audioEnd: nil, createdAt: "t")
        try dao.insert(card)
        #expect(try dao.vocabularyCard(for: "book-1", word: "ephemeral") != nil)
        #expect(try dao.vocabularyCard(for: "book-1", word: "other") == nil)
        #expect(try dao.vocabularyCard(for: "book-2", word: "ephemeral") == nil)
    }
}
