// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyDeckDraftDeduplicatorTests {
    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'T', 100)"
            )
            try db.execute(
                sql: """
                    INSERT INTO flashcard (
                        id, audiobook_id, front_text, back_text, media_timestamp, source_block_id
                    ) VALUES ('f1', 'book', 'What  is retrieval practice?', 'A', 0, 'block-1')
                    """
            )
        }
        return service
    }

    private func draft(_ cards: [GeneratedStudyDeckCardDraft]) -> GeneratedStudyDeckDraft {
        GeneratedStudyDeckDraft(cards: cards, validSourceBlockIDs: Set(cards.map(\.sourceBlockID)))
    }

    @Test func skipsAcceptedDuplicateByBlockAndNormalizedFront() throws {
        let service = try seededService()
        let duplicate = GeneratedStudyDeckCardDraft(
            id: "ai-1",
            sourceBlockID: "block-1",
            frontText: "what is Retrieval   practice?",
            backText: "B"
        )
        let freshFront = GeneratedStudyDeckCardDraft(
            id: "ai-2",
            sourceBlockID: "block-1",
            frontText: "A different question?",
            backText: "B"
        )
        let otherBlock = GeneratedStudyDeckCardDraft(
            id: "ai-3",
            sourceBlockID: "block-2",
            frontText: "What is retrieval practice?",
            backText: "B"
        )

        let result = try StudyDeckDraftDeduplicator(db: service.writer)
            .deduplicate(draft([duplicate, freshFront, otherBlock]), audiobookID: "book")

        #expect(result.skippedCount == 1)
        #expect(result.draft.cards.map(\.id) == ["ai-2", "ai-3"])
    }

    @Test func otherBooksCardsDoNotCauseSkips() throws {
        let service = try seededService()
        let card = GeneratedStudyDeckCardDraft(
            id: "ai-1",
            sourceBlockID: "block-1",
            frontText: "What is retrieval practice?",
            backText: "B"
        )

        let result = try StudyDeckDraftDeduplicator(db: service.writer)
            .deduplicate(draft([card]), audiobookID: "another-book")

        #expect(result.skippedCount == 0)
        #expect(result.draft.cards.count == 1)
    }

    @Test func passesThroughWhenNoAcceptedCards() throws {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'T', 100)"
            )
        }
        let card = GeneratedStudyDeckCardDraft(
            id: "ai-1",
            sourceBlockID: "block-1",
            frontText: "Q?",
            backText: "A"
        )
        let result = try StudyDeckDraftDeduplicator(db: service.writer)
            .deduplicate(draft([card]), audiobookID: "book")
        #expect(result.skippedCount == 0)
        #expect(result.draft.cards.count == 1)
    }

    @Test func normalizationLowercasesTrimsAndCollapsesWhitespace() {
        #expect(StudyDeckDraftDeduplicator.normalizedFront("  What\n IS   x? ") == "what is x?")
        #expect(StudyDeckDraftDeduplicator.normalizedFront("plain") == "plain")
    }
}
