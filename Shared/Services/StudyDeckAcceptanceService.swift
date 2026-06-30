// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

struct StudyDeckAcceptanceService {
    private static let logger = Logger(category: "StudyDeckAcceptanceService")
    let db: DatabaseWriter

    func accept(
        _ draft: GeneratedStudyDeckDraft,
        audiobookID: String,
        bookTitle: String,
        selectedCardIDs: Set<String>,
        now: Date = Date()
    ) throws -> [Flashcard] {
        let selectedCards = draft.cards.filter { selectedCardIDs.contains($0.id) }
        guard !selectedCards.isEmpty else { return [] }

        let deckName = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deckName.isEmpty else { throw DeckDAOError.emptyName }

        let nowString = now.ISO8601Format()
        return try db.write { db in
            let deckID = try Self.findOrCreateDeck(
                named: deckName,
                nowString: nowString,
                db: db
            )
            var acceptedCards: [Flashcard] = []

            for draftCard in selectedCards {
                let timelineMapping = try Self.timelineMapping(
                    audiobookID: audiobookID,
                    sourceBlockID: draftCard.sourceBlockID,
                    db: db
                )
                let cards = Self.makeFlashcards(
                    draftCard: draftCard,
                    audiobookID: audiobookID,
                    deckID: deckID,
                    timelineMapping: timelineMapping,
                    nowString: nowString
                )
                for card in cards {
                    try FlashcardDAO.insert(card, in: db)
                    acceptedCards.append(card)
                }
            }

            return acceptedCards
        }
    }

    private static func findOrCreateDeck(
        named name: String,
        nowString: String,
        db: Database
    ) throws -> String {
        if let existingID: String = try String.fetchOne(
            db,
            sql: "SELECT id FROM deck WHERE name = ? ORDER BY created_at, id LIMIT 1",
            arguments: [name]
        ) {
            return existingID
        }

        let id = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'auto', ?, ?)
                """,
            arguments: [id, name, nowString, nowString]
        )
        return id
    }

    private static func timelineMapping(
        audiobookID: String,
        sourceBlockID: String,
        db: Database
    ) throws -> TimelineMapping {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT audio_start_time, audio_end_time, playlist_position
                    FROM timeline_item
                    WHERE audiobook_id = :audiobookID
                      AND epub_block_id = :sourceBlockID
                      AND (source_table = 'epub_block' OR source_table IS NULL)
                    ORDER BY
                      CASE
                        WHEN source_table = 'epub_block' AND source_rowid = :sourceBlockID THEN 0
                        WHEN source_table = 'epub_block' THEN 1
                        ELSE 2
                      END,
                      is_enabled DESC,
                      CASE WHEN playlist_position IS NULL THEN 1 ELSE 0 END,
                      playlist_position,
                      audio_start_time,
                      id
                    LIMIT 1
                    """,
                arguments: [
                    "audiobookID": audiobookID,
                    "sourceBlockID": sourceBlockID,
                ]
            )
        else {
            return .fallback
        }

        let mediaTimestamp: TimeInterval = row["audio_start_time"]
        guard mediaTimestamp >= 0 else {
            return .fallback
        }

        return TimelineMapping(
            mediaTimestamp: mediaTimestamp,
            endTimestamp: row["audio_end_time"],
            playlistPosition: row["playlist_position"]
        )
    }

    private static func makeFlashcards(
        draftCard: GeneratedStudyDeckCardDraft,
        audiobookID: String,
        deckID: String,
        timelineMapping: TimelineMapping,
        nowString: String
    ) -> [Flashcard] {
        switch draftCard.kind {
        case .cloze:
            let clozeText = draftCard.clozeText ?? ""
            let deletions = ClozeParser.parseDeletions(clozeText)
            guard !deletions.isEmpty else {
                Self.logger.warning(
                    "cloze card '\(draftCard.id, privacy: .public)' produced zero deletions — dropping"
                )
                return []
            }
            return deletions.map { deletion in
                Self.flashcard(
                    frontText: ClozeParser.makeFront(text: clozeText, deletion: deletion),
                    backText: ClozeParser.makeBack(text: clozeText, deletion: deletion),
                    cardType: StudyFlashcardType.cloze,
                    clozeIndex: deletion.index,
                    draftCard: draftCard,
                    audiobookID: audiobookID,
                    deckID: deckID,
                    timelineMapping: timelineMapping,
                    nowString: nowString
                )
            }
        case .basic:
            return [
                Self.flashcard(
                    frontText: draftCard.frontText,
                    backText: draftCard.backText,
                    cardType: StudyFlashcardType.normal,
                    clozeIndex: nil,
                    draftCard: draftCard,
                    audiobookID: audiobookID,
                    deckID: deckID,
                    timelineMapping: timelineMapping,
                    nowString: nowString
                )
            ]
        }
    }

    private static func flashcard(
        frontText: String,
        backText: String,
        cardType: String,
        clozeIndex: Int?,
        draftCard: GeneratedStudyDeckCardDraft,
        audiobookID: String,
        deckID: String,
        timelineMapping: TimelineMapping,
        nowString: String
    ) -> Flashcard {
        Flashcard(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            frontText: frontText,
            backText: backText,
            mediaTimestamp: timelineMapping.mediaTimestamp,
            endTimestamp: timelineMapping.endTimestamp,
            triggerTiming: .manualOnly,
            nextReviewDate: nowString,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: deckID,
            tags: Self.tagsString(from: draftCard.tags),
            mediaJSON: nil,
            sourceBlockID: draftCard.sourceBlockID,
            playlistPosition: timelineMapping.playlistPosition,
            createdAt: nowString,
            modifiedAt: nowString,
            stability: nil,
            difficulty: nil,
            cardType: cardType,
            clozeIndex: clozeIndex
        )
    }

    private static func tagsString(from tags: [String]) -> String? {
        guard !tags.isEmpty else { return nil }
        return tags.joined(separator: " ")
    }
}

private struct TimelineMapping {
    let mediaTimestamp: TimeInterval
    let endTimestamp: TimeInterval?
    let playlistPosition: TimeInterval?

    static let fallback = TimelineMapping(
        mediaTimestamp: 0,
        endTimestamp: nil,
        playlistPosition: nil
    )
}
