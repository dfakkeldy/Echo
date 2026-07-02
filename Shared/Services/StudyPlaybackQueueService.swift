// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Materializes today's study queue into playable chapter assignments, and owns
/// the retention-neutral skip and needs-attention bookkeeping around playback.
struct StudyPlaybackQueueService {
    let db: DatabaseWriter

    enum PersistenceError: LocalizedError {
        case flashcardMissing(String)
        case nextReviewDateUnavailable

        var errorDescription: String? {
            switch self {
            case .flashcardMissing(let id):
                "Missing flashcard for study playback item: \(id)"
            case .nextReviewDateUnavailable:
                "Could not calculate the next review date."
            }
        }
    }

    /// The next playable item after a cursor, plus every unplayable item that
    /// was passed over on the way.
    struct Advance: Equatable, Sendable {
        let next: StudyPlayableItem?
        let skippedUnplayable: [StudyPlayableItem]
    }

    /// Cross-book advance is not special-cased: the next playable item may
    /// reference a different book.
    func nextPlayableItem(
        after flashcardID: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        globalNewChapterLimit: Int? = nil,
        isPlayable: (StudyPlayableItem) -> Bool = { _ in true }
    ) throws -> Advance {
        let queue = try StudyQueueBuilder(db: db).build(
            now: now,
            calendar: calendar,
            globalNewChapterLimit: globalNewChapterLimit
        )
        let playable = queue.entries.compactMap(Self.playableItem)

        let remaining: [StudyPlayableItem]
        if let flashcardID {
            if let index = playable.firstIndex(where: { $0.flashcardID == flashcardID }) {
                remaining = playable[(index + 1)...].filter { $0.flashcardID != flashcardID }
            } else {
                remaining = playable.filter { $0.flashcardID != flashcardID }
            }
        } else {
            remaining = playable
        }

        var skipped: [StudyPlayableItem] = []
        for item in remaining {
            if isPlayable(item) {
                return Advance(next: item, skippedUnplayable: skipped)
            }
            skipped.append(item)
        }

        return Advance(next: nil, skippedUnplayable: skipped)
    }

    func markSkipped(
        flashcardID: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
            throw PersistenceError.nextReviewDateUnavailable
        }

        let nowString = now.ISO8601Format()
        try db.write { db in
            guard let card = try Flashcard.fetchOne(db, key: flashcardID) else {
                throw PersistenceError.flashcardMissing(flashcardID)
            }

            try db.execute(
                sql: "UPDATE flashcard SET next_review_date = ?, modified_at = ? WHERE id = ?",
                arguments: [tomorrow.ISO8601Format(), nowString, flashcardID]
            )

            let metadataJSON = try FlashcardReviewMetadata(
                cardID: card.id,
                grade: 0,
                intervalDays: card.intervalDays,
                skipped: true
            ).encodedJSONString()

            try RealTimeEventDAO.log(
                eventType: StudyCheckpointEventType.chapterSkipped,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: card.frontText,
                subtitle: "Skipped",
                metadataJSON: metadataJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard",
                in: db
            )
        }
    }

    /// Skip is offered only when the chapter has no enabled user-created cards.
    /// Old rows with `NULL` card types are user cards.
    func isSkipEligible(assignmentCardID: String) throws -> Bool {
        try db.read { db in
            guard let card = try Flashcard.fetchOne(db, key: assignmentCardID) else {
                return false
            }

            let upperBound = card.endTimestamp ?? .greatestFiniteMagnitude
            let userCardCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM flashcard
                    WHERE audiobook_id = ?
                      AND id != ?
                      AND is_enabled = 1
                      AND (card_type IS NULL OR card_type NOT IN (?, ?))
                      AND media_timestamp >= ?
                      AND media_timestamp < ?
                    """,
                arguments: [
                    card.audiobookID,
                    card.id,
                    StudyFlashcardType.listeningAssignment,
                    StudyFlashcardType.imageAssignment,
                    card.mediaTimestamp,
                    upperBound,
                ]
            ) ?? 0

            return userCardCount == 0
        }
    }

    /// Records that a playable item could not be played so the study session can
    /// badge it instead of dropping it silently.
    func markNeedsAttention(
        item: StudyPlayableItem,
        reason: String,
        now: Date = Date()
    ) throws {
        try RealTimeEventDAO(db: db).log(
            eventType: StudyCheckpointEventType.needsAttention,
            audiobookID: item.audiobookID,
            mediaTimestamp: item.startTime,
            startedAt: now,
            endedAt: now,
            title: item.title,
            subtitle: reason,
            metadataJSON: nil,
            sourceItemID: item.flashcardID,
            sourceItemType: "flashcard"
        )
    }

    func needsAttentionFlashcardIDs(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Set<String> {
        let dayStart = calendar.startOfDay(for: now).ISO8601Format()
        return try db.read { db in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT source_item_id FROM real_time_event
                    WHERE event_type = ? AND started_at >= ? AND source_item_id IS NOT NULL
                    """,
                arguments: [StudyCheckpointEventType.needsAttention, dayStart]
            )
            return Set(ids)
        }
    }

    private static func playableItem(for entry: StudyQueueEntry) -> StudyPlayableItem? {
        guard entry.flashcard.cardType == StudyFlashcardType.listeningAssignment else {
            return nil
        }

        return StudyPlayableItem(
            flashcardID: entry.flashcard.id,
            audiobookID: entry.flashcard.audiobookID,
            chapterIndex: entry.item?.chapterIndex,
            planItemID: entry.item?.id,
            title: entry.flashcard.frontText,
            startTime: entry.flashcard.mediaTimestamp,
            endTime: entry.flashcard.endTimestamp
        )
    }
}
