// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Metadata for the recap card shown atop a scoped feed. All fields are derived at
/// query time from existing tables — no stored session summary, no schema change.
/// GPS ("where") is deferred to Phase 5 (the `session_location` table has no writer).
public struct SessionRecap: Equatable, Sendable {
    public let startedAt: Date
    public let listenedSeconds: TimeInterval
    public let coveredChapterIndices: [Int]
    public let bookmarkCount: Int
    public let cardCount: Int

    public init(
        startedAt: Date,
        listenedSeconds: TimeInterval,
        coveredChapterIndices: [Int],
        bookmarkCount: Int,
        cardCount: Int
    ) {
        self.startedAt = startedAt
        self.listenedSeconds = listenedSeconds
        self.coveredChapterIndices = coveredChapterIndices
        self.bookmarkCount = bookmarkCount
        self.cardCount = cardCount
    }
}

/// Builds a `SessionRecap` from a resolved `FeedScopeWindow`. GRDB read-only struct.
public struct SessionRecapViewModel {
    public let db: DatabaseWriter

    public init(db: DatabaseWriter) {
        self.db = db
    }

    private static let iso = ISO8601DateFormatter()

    public func recap(audiobookID: String, window: FeedScopeWindow) throws -> SessionRecap {
        try db.read { db in
            // Covered chapter range: find all chapter_index values that overlap with
            // [coveredStartPosition, coveredEndPosition]. A chapter spans from its first
            // anchor to the next chapter's first anchor (or infinity). We include a chapter
            // if its first anchor <= coveredEndPosition AND (the chapter after it starts
            // after coveredStartPosition OR there is no next chapter with a higher anchor
            // before coveredStartPosition). In practice: a chapter index is included if
            // MIN(audio_start_time) for that chapter <= coveredEndPosition AND the chapter
            // whose MIN anchor is the largest value <= coveredStartPosition (the "containing"
            // chapter) is included even if its anchor < coveredStartPosition.
            //
            // Implementation: collect per-chapter MIN anchor, keep those whose anchor
            // <= coveredEndPosition, then from that set drop chapters whose anchor is
            // < coveredStartPosition AND there exists a later chapter also with anchor
            // <= coveredStartPosition (i.e., only keep the highest-anchored chapter that
            // is still <= coveredStartPosition, plus all chapters with anchor in the range).
            var chapters: [Int] = []
            if window.coveredEndPosition > window.coveredStartPosition {
                // Compute per-chapter first anchor time.
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT eb.chapter_index AS chapter_index,
                               MIN(ti.audio_start_time) AS first_anchor
                        FROM timeline_item ti
                        JOIN epub_block eb ON eb.id = ti.epub_block_id
                        WHERE ti.audiobook_id = ?
                          AND eb.chapter_index IS NOT NULL
                          AND ti.audio_start_time >= 0
                        GROUP BY eb.chapter_index
                        ORDER BY first_anchor
                        """,
                    arguments: [audiobookID])

                // Build sorted list of (chapterIndex, firstAnchor).
                let anchors: [(index: Int, anchor: Double)] = rows.compactMap { row in
                    guard let idx = row["chapter_index"] as Int?,
                        let anc = row["first_anchor"] as Double?
                    else { return nil }
                    return (idx, anc)
                }

                // Find the "containing" chapter: the one with the largest anchor <= coveredStart.
                let containingIndex = anchors.last(where: {
                    $0.anchor <= window.coveredStartPosition
                })?.index

                for (idx, anchor) in anchors {
                    guard anchor <= window.coveredEndPosition else { break }
                    if idx == containingIndex || anchor >= window.coveredStartPosition {
                        chapters.append(idx)
                    }
                }
            }

            // Bookmarks created inside the wall-clock window.
            let startStr = Self.iso.string(from: window.startedAt)
            let endStr = Self.iso.string(from: window.endedAt)
            let bookmarkCount =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM bookmark
                        WHERE audiobook_id = ?
                          AND created_at >= ?
                          AND created_at <= ?
                        """, arguments: [audiobookID, startStr, endStr]) ?? 0

            // Cards created in the window: counted from timeline_item rows of type
            // 'ankiCard' created in the window. TimelineItemType.ankiCard.rawValue == "ankiCard".
            let cardCount =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM timeline_item
                        WHERE audiobook_id = ?
                          AND item_type = 'ankiCard'
                          AND created_at IS NOT NULL
                          AND created_at >= ?
                          AND created_at <= ?
                        """, arguments: [audiobookID, startStr, endStr]) ?? 0

            return SessionRecap(
                startedAt: window.startedAt,
                listenedSeconds: window.listenedSeconds,
                coveredChapterIndices: chapters,
                bookmarkCount: bookmarkCount,
                cardCount: cardCount
            )
        }
    }
}
