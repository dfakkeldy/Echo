// SPDX-License-Identifier: GPL-3.0-or-later

import GRDB
import Testing

@testable import Echo

@MainActor
struct ChapterCardDrafterTests {
    let drafter = ChapterCardDrafter()

    func makeService() throws -> DatabaseService {
        try DatabaseService(inMemory: ())
    }

    @Test func draftsCardsForHeadings() async throws {
        let service = try makeService()
        let bookID = "test-book"
        try service.write { db in
            try insertAudiobook(id: bookID, title: "Test Book", db: db)
            for index in 0..<3 {
                try insertHeading(
                    id: "h\(index)",
                    audiobookID: bookID,
                    title: "Chapter \(index + 1)",
                    chapterIndex: index,
                    sequenceIndex: index,
                    db: db
                )
            }
        }

        let count = try await drafter.draftCards(
            for: bookID,
            bookTitle: "Test Book",
            db: service.writer
        )
        let cardTypes = try service.read { db in
            try String.fetchAll(db, sql: "SELECT card_type FROM flashcard ORDER BY source_block_id")
        }
        let studyPlanCount = try service.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM study_plan WHERE audiobook_id = ?",
                arguments: [bookID]
            ) ?? 0
        }
        let studyPlanItemSources = try service.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT spi.source_block_id
                    FROM study_plan_item spi
                    JOIN study_plan sp ON sp.id = spi.plan_id
                    WHERE sp.audiobook_id = ?
                    ORDER BY spi.ordinal
                    """,
                arguments: [bookID]
            )
        }
        let studyPlanItemKinds = try service.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT spi.kind
                    FROM study_plan_item spi
                    JOIN study_plan sp ON sp.id = spi.plan_id
                    WHERE sp.audiobook_id = ?
                    ORDER BY spi.ordinal
                    """,
                arguments: [bookID]
            )
        }

        #expect(count == 3)
        #expect(cardTypes == Array(repeating: StudyFlashcardType.listeningAssignment, count: 3))
        #expect(studyPlanCount == 1)
        #expect(studyPlanItemSources == ["h0", "h1", "h2"])
        #expect(studyPlanItemKinds == Array(repeating: StudyPlanItemKind.chapter.rawValue, count: 3))
    }

    @Test func skipsFrontMatter() async throws {
        let service = try makeService()
        let bookID = "test-book2"
        try service.write { db in
            try insertAudiobook(id: bookID, title: "Test", db: db)
            try insertHeading(
                id: "h0",
                audiobookID: bookID,
                title: "Preface",
                chapterIndex: 0,
                sequenceIndex: 0,
                isFrontMatter: true,
                db: db
            )
            try insertHeading(
                id: "h1",
                audiobookID: bookID,
                title: "Chapter 1",
                chapterIndex: 1,
                sequenceIndex: 1,
                db: db
            )
        }

        let count = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: service.writer)

        #expect(count == 1)
    }

    @Test func skipsHiddenHeadings() async throws {
        let service = try makeService()
        let bookID = "test-book-hidden"
        try service.write { db in
            try insertAudiobook(id: bookID, title: "Test", db: db)
            try insertHeading(
                id: "h0",
                audiobookID: bookID,
                title: "Visible Chapter",
                chapterIndex: 0,
                sequenceIndex: 0,
                db: db
            )
            try insertHeading(
                id: "h1",
                audiobookID: bookID,
                title: "Hidden Chapter",
                chapterIndex: 1,
                sequenceIndex: 1,
                isHidden: true,
                db: db
            )
        }

        let count = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: service.writer)

        #expect(count == 1)
    }

    @Test func idempotentReRunDoesNotDuplicate() async throws {
        let service = try makeService()
        let bookID = "test-book3"
        try service.write { db in
            try insertAudiobook(id: bookID, title: "Test", db: db)
            try insertHeading(
                id: "h0",
                audiobookID: bookID,
                title: "Ch1",
                chapterIndex: 0,
                sequenceIndex: 0,
                db: db
            )
        }

        _ = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: service.writer)
        let second = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: service.writer)

        #expect(second == 0)
    }

    @Test func createsDeckNamedAfterBook() async throws {
        let service = try makeService()
        let bookID = "test-book4"
        try service.write { db in
            try insertAudiobook(id: bookID, title: "The Scarlet Letter", db: db)
            try insertHeading(
                id: "h0",
                audiobookID: bookID,
                title: "The Prison Door",
                chapterIndex: 0,
                sequenceIndex: 0,
                db: db
            )
        }

        _ = try await drafter.draftCards(
            for: bookID,
            bookTitle: "The Scarlet Letter",
            db: service.writer
        )
        let deckName = try service.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT name FROM deck WHERE name = ?",
                arguments: ["The Scarlet Letter"]
            )
        }

        #expect(deckName == "The Scarlet Letter")
    }

    @Test func emptyBookReturnsZero() async throws {
        let service = try makeService()
        let count = try await drafter.draftCards(
            for: "no-book",
            bookTitle: "Nothing",
            db: service.writer
        )

        #expect(count == 0)
    }

    private func insertAudiobook(id: String, title: String, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES (?, ?, 3600, '2026-06-01T00:00:00Z')
                """,
            arguments: [id, title]
        )
    }

    private func insertHeading(
        id: String,
        audiobookID: String,
        title: String,
        chapterIndex: Int,
        sequenceIndex: Int,
        isFrontMatter: Bool = false,
        isHidden: Bool = false,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO epub_block (
                    id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                    block_kind, text, chapter_index, is_front_matter, is_hidden
                )
                VALUES (?, ?, ?, ?, 0, ?, 'heading', ?, ?, ?, ?)
                """,
            arguments: [
                id,
                audiobookID,
                "chapter-\(sequenceIndex).xhtml",
                sequenceIndex,
                sequenceIndex,
                title,
                chapterIndex,
                isFrontMatter,
                isHidden,
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO timeline_item (
                    id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                    granularity_level, playlist_position, is_enabled, epub_block_id
                ) VALUES (?, ?, 'textSegment', ?, ?, ?, 1, ?, 1, ?)
                """,
            arguments: [
                "t-\(id)",
                audiobookID,
                title,
                Double(sequenceIndex) * 100,
                Double(sequenceIndex + 1) * 100,
                Double(sequenceIndex) * 100,
                id,
            ]
        )
    }
}
