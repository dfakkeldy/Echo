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

    /// Whole-book rebuild: wipes and re-materializes every word row for the book.
    /// Used by manual alignment and at the END of the AutoAlignment pipeline (one
    /// rebuild per user action). Do NOT call this once per chapter in a render
    /// loop — that is O(chapters²); use `materializeChapter` instead.
    static func materialize(audiobookID: String, writer: DatabaseWriter) throws {
        let dao = WordTimingDAO(db: writer)
        try dao.deleteAll(forAudiobook: audiobookID)
        let blocks = try alignedBlocks(audiobookID: audiobookID, blockIDs: nil, writer: writer)
        guard !blocks.isEmpty else { return }
        try dao.insert(records(from: blocks, audiobookID: audiobookID))
    }

    /// Per-chapter rebuild for the narration render loop: deletes & re-materializes
    /// ONLY `blockIDs`' word rows, leaving every other chapter's rows intact. Run
    /// once per chapter this is O(chapter), so a render run is O(N) instead of the
    /// O(N²) the whole-book `materialize` would cost when called per chapter (the
    /// pitfall AlignmentService.recalculateTimeline's doc warns about). Each narrated
    /// chapter is its own 0-based audio file, so scoping the end-bound interpolation
    /// to the chapter is also more correct than ordering all chapters' overlapping
    /// 0-based start times together.
    static func materializeChapter(
        audiobookID: String, blockIDs: [String], writer: DatabaseWriter
    ) throws {
        guard !blockIDs.isEmpty else { return }
        let dao = WordTimingDAO(db: writer)
        try dao.deleteAll(forAudiobook: audiobookID, blockIDs: blockIDs)
        let blocks = try alignedBlocks(audiobookID: audiobookID, blockIDs: blockIDs, writer: writer)
        guard !blocks.isEmpty else { return }
        try dao.insert(records(from: blocks, audiobookID: audiobookID))
    }

    // MARK: - Shared

    /// Aligned, text-bearing blocks ordered by audio time. `audio_start_time < 0`
    /// is the "unaligned" sentinel — skipped. `blockIDs == nil` fetches the whole
    /// book; a non-empty list scopes to those blocks.
    private static func alignedBlocks(
        audiobookID: String, blockIDs: [String]?, writer: DatabaseWriter
    ) throws -> [Block] {
        try writer.read { db in
            var sql = """
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
                """
            var args: [String] = [audiobookID]
            if let blockIDs, !blockIDs.isEmpty {
                sql += " AND ti.epub_block_id IN (\(databaseQuestionMarks(count: blockIDs.count)))"
                args += blockIDs
            }
            sql += " ORDER BY ti.audio_start_time"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                Block(
                    id: row["id"], text: row["text"],
                    start: row["start"], end: row["end"])
            }
        }
    }

    /// Interpolates per-word rows for a run of aligned blocks. Each block's end
    /// bound is the next block's start, else its own end, else a ~15 cps estimate
    /// so the last block still gets ranges.
    private static func records(
        from blocks: [Block], audiobookID: String
    ) -> [WordTimingRecord] {
        var records: [WordTimingRecord] = []
        for (i, block) in blocks.enumerated() {
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
        return records
    }

    /// Confidence stamped on a word whose time came from a real DTW audio match.
    private static let dtwConfidence: Double = 0.85

    /// Overrides already-materialized interpolated word times with DTW-derived
    /// audio times, per block, where a normalized DTW token maps onto a rendered
    /// word. Call AFTER `materialize` with the per-block matches accumulated
    /// during the alignment pipeline.
    ///
    /// Additive: blocks with no matches keep their interpolated rows untouched,
    /// and the refiner only retimes matched words — it never adds or deletes any.
    static func refine(
        audiobookID: String,
        dtwMatchesByBlock: [String: [TokenDTW.WordMatch]],
        writer: DatabaseWriter,
        minRunLength: Int = 3
    ) throws {
        guard !dtwMatchesByBlock.isEmpty else { return }
        let dao = WordTimingDAO(db: writer)

        var updates: [WordTimingRecord] = []
        for (blockID, matches) in dtwMatchesByBlock {
            let rows = try dao.words(forAudiobook: audiobookID, blockID: blockID)
            guard !rows.isEmpty else { continue }

            let words = rows.map {
                WordTimingInterpolator.Word(
                    index: $0.wordIndex, word: $0.word,
                    start: $0.audioStartTime, end: $0.audioEndTime)
            }
            let refined = WordTimingRefiner.refine(
                words: words, dtwMatches: matches, minRunLength: minRunLength)

            // Pair each refined word back to its stored row by position (same
            // order, same count), updating only the ones DTW retimed.
            for (row, ref) in zip(rows, refined) where ref.source == "dtw" {
                var updated = row
                updated.audioStartTime = ref.start
                updated.audioEndTime = ref.end
                updated.confidence = dtwConfidence
                updated.source = "dtw"
                updates.append(updated)
            }
        }
        try dao.update(updates)
    }
}
