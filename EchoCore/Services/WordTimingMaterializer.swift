// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Rebuilds the `word_timing` table for one audiobook from its block-level
/// timeline. Runs AFTER `AlignmentService.recalculateTimeline` so it sees the
/// final per-block `audio_start_time`s. Clears prior rows first, so each
/// (re)alignment converges (mirrors `AlignmentAnchorDAO.deleteAutoPipelineAnchors`).
enum WordTimingMaterializer {
    /// One aligned block: its text and start time, ordered by start.
    private struct Block {
        let id: String
        let text: String
        let start: TimeInterval
        let end: TimeInterval?
    }

    static func materialize(audiobookID: String, writer: DatabaseWriter) throws {
        let dao = WordTimingDAO(db: writer)
        try dao.deleteAll(forAudiobook: audiobookID)

        // Aligned, text-bearing blocks ordered by audio time. audio_start_time < 0
        // is the "unaligned" sentinel — skip those.
        let blocks: [Block] = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ti.epub_block_id AS id,
                           eb.text AS text,
                           ti.audio_start_time AS start,
                           ti.audio_end_time AS end
                    FROM timeline_item ti
                    JOIN epub_block eb ON eb.id = ti.epub_block_id
                    WHERE ti.audiobook_id = ?
                      AND ti.epub_block_id IS NOT NULL
                      AND ti.audio_start_time >= 0
                      AND eb.text IS NOT NULL AND eb.text <> ''
                    ORDER BY ti.audio_start_time
                    """, arguments: [audiobookID]
            ).map { row in
                Block(
                    id: row["id"], text: row["text"],
                    start: row["start"], end: row["end"])
            }
        }
        guard !blocks.isEmpty else { return }

        var records: [WordTimingRecord] = []
        for (i, block) in blocks.enumerated() {
            // End bound: next block's start, else this block's own end, else a
            // char-rate estimate (~15 cps) so the last block still gets ranges.
            let blockEnd: TimeInterval
            if i + 1 < blocks.count {
                blockEnd = max(block.start, blocks[i + 1].start)
            } else if let end = block.end, end > block.start {
                blockEnd = end
            } else {
                blockEnd = block.start + Double(block.text.count) / 15.0
            }

            let plain = block.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            for w in WordTimingInterpolator.interpolate(
                text: plain, blockStart: block.start, blockEnd: blockEnd)
            {
                records.append(
                    WordTimingRecord(
                        audiobookID: audiobookID, epubBlockID: block.id,
                        wordIndex: w.index, word: w.word,
                        audioStartTime: w.start, audioEndTime: w.end,
                        confidence: 0.5, source: "interpolated"))
            }
        }
        try dao.insert(records)
    }
}
