// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Loads reader timeline rows (audio ranges → EPUB blocks) for one book.
/// Extracted from `VisualListeningViewModel` so the video exporter and the
/// live stage run the identical query, including the derived-end policy:
/// NULL `audio_end_time` closes at the next row's start, else +3600s.
nonisolated enum TimelineRowLoader {
    static func rows(
        audiobookID: String,
        db: DatabaseWriter
    ) throws -> [ReaderActiveBlockResolver.TimelineRow] {
        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id,
                           ti.segment_key, eb.chapter_index
                    FROM timeline_item ti
                    LEFT JOIN epub_block eb ON eb.id = ti.epub_block_id
                    WHERE ti.audiobook_id = ? AND ti.epub_block_id IS NOT NULL AND ti.audio_start_time >= 0
                    ORDER BY ti.audio_start_time
                    """,
                arguments: [audiobookID]
            )
        }

        return rows.enumerated().compactMap { index, row in
            guard let start: TimeInterval = row["audio_start_time"],
                let blockID: String = row["epub_block_id"]
            else { return nil }

            let end: TimeInterval
            if let explicitEnd: TimeInterval = row["audio_end_time"] {
                end = explicitEnd
            } else if index + 1 < rows.count,
                let nextStart: TimeInterval = rows[index + 1]["audio_start_time"]
            {
                end = nextStart
            } else {
                end = start + 3_600
            }

            let chapterIndex: Int? = row["chapter_index"]
            let segmentKey: String? = row["segment_key"]
            return (
                start: start,
                end: end,
                blockID: blockID,
                chapterIndex: chapterIndex,
                segmentKey: segmentKey
            )
        }
    }
}
