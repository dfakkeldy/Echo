// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Drops draft cards that duplicate an already-accepted flashcard for the same book:
/// same `sourceBlockID` and normalized front text.
struct StudyDeckDraftDeduplicator {
    let db: DatabaseWriter

    struct Result {
        let draft: GeneratedStudyDeckDraft
        let skippedCount: Int
    }

    func deduplicate(
        _ draft: GeneratedStudyDeckDraft,
        audiobookID: String
    ) throws -> Result {
        let existing = try existingCardKeys(audiobookID: audiobookID)
        guard !existing.isEmpty else {
            return Result(draft: draft, skippedCount: 0)
        }

        var kept: [GeneratedStudyDeckCardDraft] = []
        var skipped = 0
        for card in draft.cards {
            let key = Self.key(sourceBlockID: card.sourceBlockID, frontText: card.frontText)
            if existing.contains(key) {
                skipped += 1
            } else {
                kept.append(card)
            }
        }

        return Result(
            draft: GeneratedStudyDeckDraft(
                cards: kept,
                validSourceBlockIDs: Set(kept.map(\.sourceBlockID))
            ),
            skippedCount: skipped
        )
    }

    static func normalizedFront(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func key(sourceBlockID: String, frontText: String) -> String {
        sourceBlockID + "|" + normalizedFront(frontText)
    }

    private func existingCardKeys(audiobookID: String) throws -> Set<String> {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_block_id, front_text FROM flashcard
                    WHERE audiobook_id = ? AND source_block_id IS NOT NULL
                    """,
                arguments: [audiobookID]
            )
            return Set(
                rows.map { row in
                    Self.key(
                        sourceBlockID: row["source_block_id"],
                        frontText: row["front_text"]
                    )
                }
            )
        }
    }
}
