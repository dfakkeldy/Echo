// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Immutable playback data shared by the iOS and Mac reader loaders.
nonisolated struct ReaderPlaybackSnapshot: Sendable {
    let timeline: [ReaderActiveBlockResolver.TimelineRow]
    let timelineIndex: ReaderActiveBlockResolver.TimelineIndex
    let words: [ReaderActiveBlockResolver.WordRow]
    let wordIndex: ReaderActiveBlockResolver.WordIndex
    let alignmentStatus: [String: String]
    let audioStart: [String: TimeInterval]
    let chapterIndex: [String: Int?]

    static func load(audiobookID: String, db: any DatabaseWriter) throws -> Self {
        try db.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: """
                    SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id,
                           ti.segment_key, ti.alignment_status, eb.chapter_index
                    FROM timeline_item ti LEFT JOIN epub_block eb ON eb.id = ti.epub_block_id
                    WHERE ti.audiobook_id = ? AND ti.epub_block_id IS NOT NULL AND ti.audio_start_time >= 0
                    ORDER BY ti.audio_start_time
                    """, arguments: [audiobookID])
            var timeline: [ReaderActiveBlockResolver.TimelineRow] = []
            var status: [String: String] = [:]
            var starts: [String: TimeInterval] = [:]
            var chapters: [String: Int?] = [:]
            for (i, row) in rows.enumerated() {
                guard let start: Double = row["audio_start_time"],
                    let id: String = row["epub_block_id"]
                else { continue }
                let next: Double? = i + 1 < rows.count ? rows[i + 1]["audio_start_time"] : nil
                let end: Double = row["audio_end_time"] ?? next ?? (start + 3600)
                let chapter: Int? = row["chapter_index"]
                let segment: String? = row["segment_key"]
                timeline.append((start, end, id, chapter, segment))
                starts[id] = start
                chapters[id] = chapter
                status[id] = row["alignment_status"]
            }
            let records =
                try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_start_time"))
                .fetchAll(connection)
            let words: [ReaderActiveBlockResolver.WordRow] = records.map {
                ($0.audioStartTime, $0.audioEndTime, $0.epubBlockID, $0.wordIndex)
            }
            return Self(
                timeline: timeline, timelineIndex: .init(rows: timeline), words: words,
                wordIndex: .init(rows: words), alignmentStatus: status,
                audioStart: starts, chapterIndex: chapters)
        }
    }
}
