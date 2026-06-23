// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Read model for the unified feed: answers "does this audio chapter have any
/// aligned audio?" honestly.
///
/// Why a range test and not a single lookup: the auto-alignment pipeline places
/// anchors on the content blocks it can match (paragraphs/sentences), which are
/// usually NOT the chapter's heading block. Testing only the heading block would
/// report a fully-aligned chapter as "no audio". So we test whether ANY block
/// whose `chapter_index` equals `chapterIndex` carries an anchor.
struct ChapterAudioStatusResolver {
    let db: DatabaseWriter

    /// True if any block in `chapterIndex` (for `audiobookID`) has an alignment
    /// anchor. False when the chapter has no blocks (e.g. front matter / unknown).
    func hasAudio(audiobookID: String, chapterIndex: Int) throws -> Bool {
        let blockIDs = try EPubBlockDAO(db: db)
            .blocks(for: audiobookID, chapterIndex: chapterIndex)
            .map(\.id)
        guard !blockIDs.isEmpty else { return false }
        return try AlignmentAnchorDAO(db: db)
            .hasAnchor(for: audiobookID, anyOf: blockIDs)
    }

    /// The set of chapter indices (for `audiobookID`) that have at least one
    /// alignment anchor anywhere in their block range. One query for the whole
    /// book — the feed needs every chapter's status on each reload, so N per-
    /// chapter lookups would be wasteful. Front-matter blocks (null
    /// `chapter_index`) are excluded; the feed groups them under key -1 which by
    /// definition has no audio in practice.
    func chaptersWithAudio(audiobookID: String) throws -> Set<Int> {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT eb.chapter_index AS chapter_index
                    FROM epub_block eb
                    JOIN alignment_anchor aa ON aa.epub_block_id = eb.id
                    WHERE eb.audiobook_id = ? AND eb.chapter_index IS NOT NULL
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
