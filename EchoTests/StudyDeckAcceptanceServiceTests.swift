// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyDeckAcceptanceServiceTests {
    @Test func insertsOnlySelectedCardsInDraftOrder() throws {
        let service = try seededService()
        let acceptance = StudyDeckAcceptanceService(db: service.writer)

        let accepted = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-3", "draft-1"],
            now: fixedNow
        )

        #expect(accepted.map(\.frontText) == ["Front 1", "Front 3"])
        #expect(accepted.map(\.sourceBlockID) == ["block-1", "block-3"])
        #expect(Set(accepted.map(\.id)).count == 2)
        #expect(accepted.allSatisfy { !$0.id.hasPrefix("draft-") })

        let persisted = try persistedCards(in: service)
        #expect(persisted.map(\.frontText).sorted() == ["Front 1", "Front 3"])
    }

    @Test func acceptedCardsPreserveDraftDataDeckTimestampsAndDefaults() throws {
        let service = try seededService()
        let acceptance = StudyDeckAcceptanceService(db: service.writer)
        let nowString = fixedNow.ISO8601Format()

        let accepted = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: " Synthetic Study Book ",
            selectedCardIDs: ["draft-1"],
            now: fixedNow
        )

        let card = try #require(accepted.first)
        let deckID = try #require(card.deckID)
        let deck = try #require(try deck(id: deckID, in: service))

        #expect(deck.name == "Synthetic Study Book")
        #expect(deck.source == "auto")
        #expect(deck.createdAt == nowString)
        #expect(deck.modifiedAt == nowString)

        #expect(card.audiobookID == "book")
        #expect(card.frontText == "Front 1")
        #expect(card.backText == "Back 1")
        #expect(card.sourceBlockID == "block-1")
        #expect(card.tags == "generated task3")
        #expect(card.mediaTimestamp == 12.5)
        #expect(card.endTimestamp == 18.75)
        #expect(card.playlistPosition == 4.25)
        #expect(card.createdAt == nowString)
        #expect(card.modifiedAt == nowString)
        #expect(card.triggerTiming == .manualOnly)
        #expect(card.nextReviewDate == nowString)
        #expect(card.intervalDays == 0)
        #expect(card.easeFactor == 2.5)
        #expect(card.repetitions == 0)
        #expect(card.lastReviewedAt == nil)
        #expect(card.lastGrade == nil)
        #expect(card.isEnabled)
        #expect(card.mediaJSON == nil)
        #expect(card.stability == nil)
        #expect(card.difficulty == nil)
        #expect(card.cardType == StudyFlashcardType.normal)
        #expect(card.clozeIndex == nil)

        let persisted = try #require(try flashcard(id: card.id, in: service))
        #expect(persisted.deckID == deckID)
        #expect(persisted.sourceBlockID == "block-1")
        #expect(persisted.nextReviewDate == nowString)
    }

    @Test func reusesExistingDeckForSameBookTitle() throws {
        let service = try seededService()
        let acceptance = StudyDeckAcceptanceService(db: service.writer)

        let first = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-1"],
            now: fixedNow
        )
        let second = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: "  Synthetic Study Book  ",
            selectedCardIDs: ["draft-2"],
            now: fixedNow.addingTimeInterval(60)
        )

        #expect(try deckCount(in: service) == 1)
        #expect(first.first?.deckID == second.first?.deckID)
    }

    @Test func insertSyncsTimelineRowWithSourceBlockID() throws {
        let service = try seededService()
        let acceptance = StudyDeckAcceptanceService(db: service.writer)

        let accepted = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-2"],
            now: fixedNow
        )

        let card = try #require(accepted.first)
        let timeline = try #require(try flashcardTimeline(for: card.id, in: service))
        #expect(timeline.id == "ankiCard-\(card.id)")
        #expect(timeline.sourceTable == "flashcard")
        #expect(timeline.sourceRowid == card.id)
        #expect(timeline.epubBlockID == "block-2")
        #expect(timeline.audioStartTime == 28.0)
        #expect(timeline.audioEndTime == nil)
        #expect(timeline.playlistPosition == nil)
    }

    @Test func basicDraftProducesOneRowWithCardTypeNormal() throws {
        let service = try seededService()
        let acceptance = StudyDeckAcceptanceService(db: service.writer)

        let accepted = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-1"],
            now: fixedNow
        )

        #expect(accepted.count == 1)
        let card = try #require(accepted.first)
        #expect(card.cardType == StudyFlashcardType.normal)
        #expect(card.clozeIndex == nil)

        let persisted = try persistedCards(in: service)
        #expect(persisted.count == 1)
        #expect(persisted[0].cardType == StudyFlashcardType.normal)
        #expect(persisted[0].clozeIndex == nil)
    }

    @Test func clozeDraftExpandsIntoOneCardPerDeletion() throws {
        let service = try seededService()
        let acceptance = StudyDeckAcceptanceService(db: service.writer)

        // "The {{c1::heart}} pumps {{c2::blood}}." — anchored to block-1 which has a timeline row
        let clozeDraft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-draft-1",
                    sourceBlockID: "block-1",
                    frontText: "The heart pumps blood.",
                    backText: "The heart pumps blood.",
                    tags: ["generated", "cloze"],
                    kind: .cloze,
                    clozeText: "The {{c1::heart}} pumps {{c2::blood}}."
                )
            ],
            validSourceBlockIDs: ["block-1"]
        )

        let accepted = try acceptance.accept(
            clozeDraft,
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["cloze-draft-1"],
            now: fixedNow
        )

        // Two cloze deletions → two flashcard rows
        #expect(accepted.count == 2)

        let sortedByIndex = accepted.sorted { ($0.clozeIndex ?? 0) < ($1.clozeIndex ?? 0) }

        let card1 = try #require(sortedByIndex.first)
        let card2 = try #require(sortedByIndex.last)

        // Both cards have card_type = "cloze"
        #expect(card1.cardType == StudyFlashcardType.cloze)
        #expect(card2.cardType == StudyFlashcardType.cloze)

        // cloze_index values are 1 and 2
        #expect(card1.clozeIndex == 1)
        #expect(card2.clozeIndex == 2)

        // Fronts blank the answer; backs reveal it
        #expect(card1.frontText == "The [...] pumps {{c2::blood}}.")
        #expect(card1.backText == "The [heart] pumps {{c2::blood}}.")
        #expect(card2.frontText == "The {{c1::heart}} pumps [...].")
        #expect(card2.backText == "The {{c1::heart}} pumps [blood].")

        // Shared metadata from the draft (same source block)
        #expect(card1.sourceBlockID == "block-1")
        #expect(card2.sourceBlockID == "block-1")
        #expect(card1.mediaTimestamp == 12.5)
        #expect(card2.mediaTimestamp == 12.5)

        // Both rows persisted with correct card_type / cloze_index in DB
        let persisted = try persistedCards(in: service)
        #expect(persisted.count == 2)
        #expect(persisted.allSatisfy { $0.cardType == StudyFlashcardType.cloze })
        let persistedIndices = Set(persisted.compactMap(\.clozeIndex))
        #expect(persistedIndices == [1, 2])
    }

    @Test func fallsBackToZeroTimestampsWhenSourceTimelineIsAbsent() throws {
        let service = try seededService()
        let acceptance = StudyDeckAcceptanceService(db: service.writer)

        let accepted = try acceptance.accept(
            draft(),
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            selectedCardIDs: ["draft-4"],
            now: fixedNow
        )

        let card = try #require(accepted.first)
        #expect(card.sourceBlockID == "block-4")
        #expect(card.mediaTimestamp == 0)
        #expect(card.endTimestamp == nil)
        #expect(card.playlistPosition == nil)

        let timeline = try #require(try flashcardTimeline(for: card.id, in: service))
        #expect(timeline.epubBlockID == "block-4")
        #expect(timeline.audioStartTime == 0)
        #expect(timeline.audioEndTime == nil)
        #expect(timeline.playlistPosition == nil)
    }

    private var fixedNow: Date {
        Date(timeIntervalSince1970: 1_750_100_000)
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Synthetic Study Book', 3600, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter,
                        created_at
                    ) VALUES
                    ('block-1', 'book', 'ch1.xhtml', 0, 0, 0, 'paragraph', 'Synthetic idea 1.', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-2', 'book', 'ch1.xhtml', 0, 1, 1, 'paragraph', 'Synthetic idea 2.', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-3', 'book', 'ch2.xhtml', 1, 0, 2, 'paragraph', 'Synthetic idea 3.', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    ('block-4', 'book', 'ch2.xhtml', 1, 1, 3, 'paragraph', 'Synthetic idea 4.', NULL, 1, 0, 0, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time,
                        audio_end_time, granularity_level, playlist_position, is_enabled,
                        source_table, source_rowid, epub_block_id
                    ) VALUES
                    ('epub-block-1', 'book', 'textSegment', 'Block 1', 12.5, 18.75, 1, 4.25, 1, 'epub_block', 'block-1', 'block-1'),
                    ('epub-block-2', 'book', 'textSegment', 'Block 2', 28.0, NULL, 1, NULL, 1, 'epub_block', 'block-2', 'block-2'),
                    ('epub-block-3', 'book', 'textSegment', 'Block 3', 42.0, 47.0, 1, 10.0, 1, 'epub_block', 'block-3', 'block-3')
                    """
            )
        }
        return service
    }

    private func draft() -> GeneratedStudyDeckDraft {
        GeneratedStudyDeckDraft(
            cards: [
                cardDraft(id: "draft-1", sourceBlockID: "block-1"),
                cardDraft(id: "draft-2", sourceBlockID: "block-2"),
                cardDraft(id: "draft-3", sourceBlockID: "block-3"),
                cardDraft(id: "draft-4", sourceBlockID: "block-4"),
            ],
            validSourceBlockIDs: ["block-1", "block-2", "block-3", "block-4"]
        )
    }

    private func cardDraft(id: String, sourceBlockID: String) -> GeneratedStudyDeckCardDraft {
        GeneratedStudyDeckCardDraft(
            id: id,
            sourceBlockID: sourceBlockID,
            frontText: "Front \(sourceBlockID.suffix(1))",
            backText: "Back \(sourceBlockID.suffix(1))",
            tags: ["generated", "task3"]
        )
    }

    private func persistedCards(in service: DatabaseService) throws -> [Flashcard] {
        try service.read { db in
            try Flashcard
                .order(Column("front_text"))
                .fetchAll(db)
        }
    }

    private func flashcard(id: String, in service: DatabaseService) throws -> Flashcard? {
        try service.read { db in
            try Flashcard.fetchOne(db, key: id)
        }
    }

    private func deck(id: String, in service: DatabaseService) throws -> Deck? {
        try service.read { db in
            try Deck.fetchOne(db, key: id)
        }
    }

    private func deckCount(in service: DatabaseService) throws -> Int {
        try service.read { db in
            try Deck.fetchCount(db)
        }
    }

    private func flashcardTimeline(
        for cardID: String,
        in service: DatabaseService
    ) throws -> TimelineSnapshot? {
        try service.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, source_table, source_rowid, epub_block_id,
                               audio_start_time, audio_end_time, playlist_position
                        FROM timeline_item
                        WHERE source_table = 'flashcard' AND source_rowid = ?
                        """,
                    arguments: [cardID]
                )
            else {
                return nil
            }

            return TimelineSnapshot(
                id: row["id"],
                sourceTable: row["source_table"],
                sourceRowid: row["source_rowid"],
                epubBlockID: row["epub_block_id"],
                audioStartTime: row["audio_start_time"],
                audioEndTime: row["audio_end_time"],
                playlistPosition: row["playlist_position"]
            )
        }
    }
}

private struct TimelineSnapshot: Equatable {
    let id: String
    let sourceTable: String?
    let sourceRowid: String?
    let epubBlockID: String?
    let audioStartTime: TimeInterval
    let audioEndTime: TimeInterval?
    let playlistPosition: TimeInterval?
}
