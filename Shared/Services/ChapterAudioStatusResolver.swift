// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Read model for the unified feed: answers "does this audio chapter have any
/// playable audio?" honestly.
///
/// Source of truth is `timeline_item.audio_start_time >= 0` — the same per-block
/// audio mapping the reader, scrubber, and read-along already use. This counts a
/// chapter as having audio whether the timestamp was anchor-locked (on-device
/// narration / WhisperKit auto-align, which also write `alignment_anchor`) OR
/// interpolated/estimated by `AlignmentService.recalculateTimeline` (imported
/// m4b + EPUB, which writes NO anchors). The earlier implementation keyed on
/// `alignment_anchor`, so the Audio / Pics+Audio chips blanked for estimated-import
/// books even though their audio plays and reads along fine.
///
/// Why a range test and not a single lookup: the alignment pipeline timestamps the
/// content blocks it can match (paragraphs/sentences), which are usually NOT the
/// chapter's heading block. Testing only the heading would report a fully-aligned
/// chapter as "no audio". So we test whether ANY block whose `chapter_index` equals
/// `chapterIndex` carries a real timestamp.
struct ChapterAudioStatusResolver {
    let db: DatabaseWriter

    /// True if any block in `chapterIndex` (for `audiobookID`) has a real audio
    /// timestamp (`timeline_item.audio_start_time >= 0`). False when the chapter has
    /// no blocks (e.g. front matter / unknown) or only unaligned (`-1`) rows.
    func hasAudio(audiobookID: String, chapterIndex: Int) throws -> Bool {
        let blockIDs = try EPubBlockDAO(db: db)
            .blocks(for: audiobookID, chapterIndex: chapterIndex)
            .map(\.id)
        guard !blockIDs.isEmpty else { return false }
        return try db.read { db in
            let placeholders = databaseQuestionMarks(count: blockIDs.count)
            let found = try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM timeline_item
                    WHERE audiobook_id = ? AND audio_start_time >= 0
                      AND epub_block_id IN (\(placeholders))
                    LIMIT 1
                    """,
                arguments: StatementArguments([audiobookID] + blockIDs))
            return found != nil
        }
    }

    /// The set of chapter indices (for `audiobookID`) that have at least one block
    /// with a real audio timestamp anywhere in their block range. One query for the
    /// whole book — the feed needs every chapter's status on each reload, so N per-
    /// chapter lookups would be wasteful. Front-matter blocks (null `chapter_index`)
    /// are excluded; the feed groups them under key -1 which by definition has no
    /// audio in practice.
    func chaptersWithAudio(audiobookID: String) throws -> Set<Int> {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT eb.chapter_index AS chapter_index
                    FROM epub_block eb
                    JOIN timeline_item ti
                      ON ti.epub_block_id = eb.id AND ti.audiobook_id = eb.audiobook_id
                    WHERE eb.audiobook_id = ? AND eb.chapter_index IS NOT NULL
                      AND ti.audio_start_time >= 0
                    """,
                arguments: [audiobookID])
            var result: Set<Int> = []
            for row in rows {
                if let idx: Int = row["chapter_index"] { result.insert(idx) }
            }
            return result
        }
    }
}
