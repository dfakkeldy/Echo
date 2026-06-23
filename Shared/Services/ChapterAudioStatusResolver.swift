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
}
