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

    /// Materializes the narration render loop's word rows for one chapter.
    ///
    /// Rows are written on the **source** word basis — the words the reader
    /// shows and indexes — even though the audio was produced from the narrated
    /// text. `TextNormalizer` speaks "1,200" as "one thousand two hundred", so
    /// the spoken word sequence can be longer than the authored one; each source
    /// word takes one row spanning all the narrated words it produced.
    ///
    /// Returns the per-block expansion counts that were applied, so
    /// `refineWithSynthesis` can fold the narrated-basis synthesis timings onto
    /// these same rows. A block whose narration cannot be aligned back onto its
    /// source words is absent from the result and keeps rows on the spoken
    /// basis, which the sidecar export guard will then (correctly) decline.
    @discardableResult
    static func materializeSynthesizedChapter(
        audiobookID: String,
        speechRangesByBlock: [String: [NarrationSpeechRange]],
        writer: DatabaseWriter
    ) throws -> [String: [Int]] {
        let blockIDs = Array(speechRangesByBlock.keys)
        guard !blockIDs.isEmpty else { return [:] }

        let sourceTextByBlockID = try narratedSourceText(
            audiobookID: audiobookID, blockIDs: blockIDs, writer: writer)

        let dao = WordTimingDAO(db: writer)
        try dao.deleteAll(forAudiobook: audiobookID, blockIDs: blockIDs)

        var records: [WordTimingRecord] = []
        var expansionCountsByBlock: [String: [Int]] = [:]
        for (blockID, ranges) in speechRangesByBlock {
            let ordered = ranges.sorted { $0.start < $1.start }

            // The block's spoken words and their interpolated spans, in reading
            // order across every range the block was synthesized in.
            var spokenWords: [String] = []
            var spokenTimings: [ChunkWordTiming] = []
            for range in ordered {
                guard !WordTokenizer.words(in: range.text).isEmpty else { continue }
                for interpolated in WordTimingInterpolator.interpolate(
                    text: range.text,
                    blockStart: range.start,
                    blockEnd: range.end)
                {
                    spokenTimings.append(
                        ChunkWordTiming(
                            wordIndex: spokenTimings.count,
                            start: interpolated.start,
                            end: interpolated.end))
                    spokenWords.append(interpolated.word)
                }
            }
            guard !spokenTimings.isEmpty else { continue }

            if let sourceText = sourceTextByBlockID[blockID],
                let counts = NarratedWordAlignment.expansionCounts(
                    source: sourceText, narrated: spokenWords.joined(separator: " ")),
                let folded = NarratedWordAlignment.collapse(spokenTimings, counts: counts)
            {
                let sourceWords = WordTokenizer.words(in: sourceText).map(String.init)
                for (wordIndex, timing) in folded.enumerated() {
                    records.append(
                        WordTimingRecord(
                            audiobookID: audiobookID,
                            epubBlockID: blockID,
                            wordIndex: wordIndex,
                            word: sourceWords[wordIndex],
                            audioStartTime: timing.start,
                            audioEndTime: timing.end,
                            confidence: 0.7,
                            source: "synthesized"))
                }
                expansionCountsByBlock[blockID] = counts
                continue
            }

            // Unalignable: keep the spoken basis rather than guess a mapping.
            for (rangeIndex, range) in ordered.enumerated() {
                guard !WordTokenizer.words(in: range.text).isEmpty else { continue }
                for interpolated in WordTimingInterpolator.interpolate(
                    text: range.text,
                    blockStart: range.start,
                    blockEnd: range.end)
                {
                    records.append(
                        WordTimingRecord(
                            audiobookID: audiobookID,
                            epubBlockID: blockID,
                            wordIndex: rangeIndex * 10_000 + interpolated.index,
                            word: interpolated.word,
                            audioStartTime: interpolated.start,
                            audioEndTime: interpolated.end,
                            confidence: 0.7,
                            source: "synthesized"))
                }
            }
        }
        try dao.insert(records)
        return expansionCountsByBlock
    }

    /// The source text each block's word rows must be keyed to — the same
    /// policy the sidecar export and import validate against.
    private static func narratedSourceText(
        audiobookID: String, blockIDs: [String], writer: DatabaseWriter
    ) throws -> [String: String] {
        try writer.read { db in
            let sql = """
                SELECT id, text, block_kind, narration_text
                FROM epub_block
                WHERE audiobook_id = ?
                  AND id IN (\(databaseQuestionMarks(count: blockIDs.count)))
                """
            let rows = try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments([audiobookID] + blockIDs))
            var textByID: [String: String] = [:]
            for row in rows {
                guard
                    let text = NarratedBlockText.text(
                        blockKind: row["block_kind"],
                        sourceText: row["text"],
                        narrationText: row["narration_text"]
                    ),
                    !text.isEmpty
                else { continue }
                textByID[row["id"]] = text
            }
            return textByID
        }
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
                       eb.block_kind AS block_kind,
                       eb.narration_text AS narration_text,
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
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap {
                row in
                guard
                    let text = NarratedBlockText.text(
                        blockKind: row["block_kind"],
                        sourceText: row["text"],
                        narrationText: row["narration_text"]
                    ),
                    !text.isEmpty
                else { return nil }
                return Block(
                    id: row["id"], text: text,
                    start: row["start"], end: row["end"])
            }
        }
    }

    /// Interpolates per-word rows for a run of aligned blocks. Each block's end
    /// bound is its explicit end, else the next block's start, else a ~15 cps
    /// estimate so the last block still gets ranges.
    private static func records(
        from blocks: [Block], audiobookID: String
    ) -> [WordTimingRecord] {
        var records: [WordTimingRecord] = []
        for (i, block) in blocks.enumerated() {
            let blockEnd: TimeInterval
            if let end = block.end, end > block.start {
                blockEnd = end
            } else if i + 1 < blocks.count {
                blockEnd = max(block.start, blocks[i + 1].start)
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

    /// Confidence stamped on a word whose time came from the synthesis-time
    /// duration head (above interpolation 0.5; on par with / above DTW 0.85).
    private static let synthesisConfidence: Double = 0.9

    /// Overrides already-materialized interpolated word times with synthesis-time
    /// timings, per block, when the per-block word counts match. A count mismatch
    /// (text normalization / G2P changed the word tokenization) leaves that
    /// block's interpolated rows untouched — the safety guard for the
    /// phoneme-group↔source-word mapping. Returns the number of blocks overridden.
    ///
    /// Mirrors `refine(...)`: additive, retimes matched rows only, never adds or
    /// deletes rows. Call AFTER `materializeChapter` has written the interpolated
    /// baseline for these blocks.
    @discardableResult
    /// `expansionCountsByBlock` carries the narrated-to-source word mapping
    /// `materializeSynthesizedChapter` applied. Synthesis timings are indexed by
    /// the words Kokoro *spoke*, so a block whose narration expanded a number
    /// has more timings than rows; folding them with the block's counts gives
    /// each source word one span before the rows are retimed. Blocks without a
    /// mapping keep the historical one-timing-per-row reading.
    static func refineWithSynthesis(
        audiobookID: String,
        synthesisByBlock: [String: [ChunkWordTiming]],
        expansionCountsByBlock: [String: [Int]] = [:],
        writer: DatabaseWriter
    ) throws -> Int {
        guard !synthesisByBlock.isEmpty else { return 0 }
        let dao = WordTimingDAO(db: writer)
        var updates: [WordTimingRecord] = []
        var blocksOverridden = 0
        for (blockID, timings) in synthesisByBlock {
            let rows = try dao.words(forAudiobook: audiobookID, blockID: blockID)
            guard !rows.isEmpty else { continue }
            let sortedTimings = timings.sorted { $0.wordIndex < $1.wordIndex }
            var timingsByIndex = sortedTimings
            if let counts = expansionCountsByBlock[blockID],
                counts.count == rows.count,
                let folded = NarratedWordAlignment.collapse(sortedTimings, counts: counts)
            {
                timingsByIndex = folded
            }
            guard rows.count == timingsByIndex.count else { continue }
            let rowsByIndex = rows.sorted { $0.wordIndex < $1.wordIndex }
            for (row, t) in zip(rowsByIndex, timingsByIndex) {
                var updated = row
                updated.audioStartTime = t.start
                updated.audioEndTime = t.end
                updated.confidence = synthesisConfidence
                updated.source = "synthesis"
                updates.append(updated)
            }
            blocksOverridden += 1
        }
        try dao.update(updates)
        return blocksOverridden
    }

    /// Confidence stamped on a word whose time was carried by an
    /// `alignment.json` sidecar. Sidecar words are exported from synthesis-time
    /// timings (the duration head's known-true times), so they carry the same
    /// confidence as `synthesis` rows — above interpolation (0.5) and DTW (0.85).
    private static let sidecarConfidence: Double = 0.9

    /// The outcome of an `applySidecarWords` pass, so callers can log which
    /// blocks took sidecar timings and which fell back — partial application
    /// is otherwise invisible (the J-Space QA "755 blocks, 0 rows" blind spot).
    struct SidecarWordApplication: Equatable {
        /// Blocks whose interpolated rows were overridden with sidecar timings.
        var blocksApplied = 0
        /// Total sidecar word rows written across `blocksApplied`.
        var wordsApplied = 0
        /// Per-block skips where the sidecar's word count disagreed with the
        /// block's tokenized rows (array-order↔wordIndex would drift).
        var mismatches: [Mismatch] = []
        /// Blocks that carried sidecar words but had no materialized rows to
        /// override (block unaligned / never made it into the timeline).
        var blocksWithoutRows = 0

        struct Mismatch: Equatable {
            let blockID: String
            /// Rows the block was materialized with (its tokenized-text count).
            let blockRows: Int
            /// Words the sidecar carried for the block.
            let sidecarWords: Int
        }
    }

    /// Overrides already-materialized word times with the word-level timings an
    /// `alignment.json` sidecar carried for `blockID`s that resolved locally.
    /// Call AFTER the sidecar anchors were ingested and the timeline/word
    /// materialization has run — the block's rows come from the block's
    /// tokenized text, so a per-block word-count mismatch means the sidecar's
    /// word list can't be trusted (array order == wordIndex would drift) and
    /// that block keeps its interpolated rows.
    ///
    /// Mirrors `refineWithSynthesis(...)`: additive, retimes matched rows only,
    /// never adds or deletes rows. Returns a per-pass summary (blocks/words
    /// applied plus the per-block mismatches) so the importer can log why any
    /// block stayed interpolated instead of the count silently reading zero.
    ///
    /// Note: a later in-app machine re-alignment (auto-alignment / transcript
    /// DTW) rebuilds the book's word rows and supersedes sidecar words —
    /// accepted v1 behavior, consistent with machine anchors being cleared per
    /// alignment run.
    @discardableResult
    static func applySidecarWords(
        audiobookID: String,
        sidecarWordsByBlock: [String: [AlignmentSidecar.Anchor.Word]],
        writer: DatabaseWriter
    ) throws -> SidecarWordApplication {
        var result = SidecarWordApplication()
        guard !sidecarWordsByBlock.isEmpty else { return result }
        let dao = WordTimingDAO(db: writer)
        var updates: [WordTimingRecord] = []
        for (blockID, words) in sidecarWordsByBlock {
            // Rows arrive ordered by word_index — the same reading order as the
            // sidecar's words array (array position == wordIndex).
            let rows = try dao.words(forAudiobook: audiobookID, blockID: blockID)
            guard !rows.isEmpty else {
                result.blocksWithoutRows += 1
                continue
            }
            guard rows.count == words.count else {
                result.mismatches.append(
                    .init(blockID: blockID, blockRows: rows.count, sidecarWords: words.count))
                continue
            }
            for (row, word) in zip(rows, words) {
                var updated = row
                updated.audioStartTime = word.start
                updated.audioEndTime = word.end
                updated.confidence = sidecarConfidence
                updated.source = "sidecar"
                updates.append(updated)
            }
            result.blocksApplied += 1
            result.wordsApplied += words.count
        }
        try dao.update(updates)
        return result
    }
}
