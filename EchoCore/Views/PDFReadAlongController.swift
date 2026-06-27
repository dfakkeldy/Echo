// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

/// Drives page auto-follow and best-effort word highlighting for a narrated PDF.
///
/// Mirrors `ReaderFeedViewModel`'s cache-loading pattern (timeline ⋈ epub_block
/// JOIN, word timings) and delegates all resolution to the shared
/// `ReaderActiveBlockResolver` — does NOT duplicate that logic.
///
/// Load once via `load(audiobookID:db:)`, then query on every playback tick.
/// All APIs are @MainActor-safe (reads from in-memory caches only after load).
@MainActor
@Observable
final class PDFReadAlongController {
    private let logger = Logger(category: "PDFReadAlongController")

    // MARK: - In-memory caches (loaded once)

    private var timelineCache: [ReaderActiveBlockResolver.TimelineRow] = []
    private var wordCache: [ReaderActiveBlockResolver.WordRow] = []

    /// blockID → page index, from `pdf_block_page`.
    private var pageIndexByBlockID: [String: Int] = [:]

    /// blockID → block text (for word-text lookup via WordTokenizer).
    private var blockTextByID: [String: String] = [:]

    private(set) var isLoaded = false

    // MARK: - Load

    /// Loads all caches from the database. Safe to call multiple times (re-loads).
    /// Mirrors exactly the query ReaderFeedViewModel.reload() uses for its
    /// `timelineCache` and `wordCache`.
    func load(audiobookID: String, db: DatabaseWriter) {
        do {
            // 1. Timeline cache — same LEFT JOIN epub_block query as ReaderFeedViewModel
            let rows = try db.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id,
                               ti.segment_key, ti.alignment_status, eb.chapter_index
                        FROM timeline_item ti
                        LEFT JOIN epub_block eb ON eb.id = ti.epub_block_id
                        WHERE ti.audiobook_id = ? AND ti.epub_block_id IS NOT NULL AND ti.audio_start_time >= 0
                        ORDER BY ti.audio_start_time
                        """, arguments: [audiobookID])
            }

            var newTimeline: [ReaderActiveBlockResolver.TimelineRow] = []
            for (i, row) in rows.enumerated() {
                guard let start: TimeInterval = row["audio_start_time"],
                    let blockID: String = row["epub_block_id"]
                else { continue }

                let end: TimeInterval
                if let explicitEnd: TimeInterval = row["audio_end_time"] {
                    end = explicitEnd
                } else if i + 1 < rows.count,
                    let nextStart: TimeInterval = rows[i + 1]["audio_start_time"]
                {
                    end = nextStart
                } else {
                    end = start + 3600
                }
                let chapterIndex: Int? = row["chapter_index"]
                let segmentKey: String? = row["segment_key"]
                newTimeline.append((start, end, blockID, chapterIndex, segmentKey))
            }
            timelineCache = newTimeline

            // 2. Word cache — same as ReaderFeedViewModel
            let words = try WordTimingDAO(db: db).words(forAudiobook: audiobookID)
            wordCache = words.map {
                (
                    start: $0.audioStartTime, end: $0.audioEndTime,
                    blockID: $0.epubBlockID, wordIndex: $0.wordIndex
                )
            }

            // 3. Page index map from pdf_block_page
            let pageRows = try PDFBlockPageDAO(db: db).rows(for: audiobookID)
            pageIndexByBlockID = Dictionary(
                pageRows.map { ($0.epubBlockID, $0.pageIndex) },
                uniquingKeysWith: { first, _ in first })

            // 4. Block text map — needed for wordText(blockID:wordIndex:)
            // Fetch from epub_block directly (no need for the full EPubBlockRecord overhead).
            let blockRows = try db.read { database in
                try Row.fetchAll(
                    database,
                    sql:
                        "SELECT id, text FROM epub_block WHERE audiobook_id = ? AND text IS NOT NULL",
                    arguments: [audiobookID])
            }
            blockTextByID = Dictionary(
                blockRows.compactMap { row -> (String, String)? in
                    guard let id: String = row["id"], let text: String = row["text"]
                    else { return nil }
                    return (id, text)
                },
                uniquingKeysWith: { first, _ in first })

            isLoaded = true
            logger.debug(
                "Loaded PDF read-along caches: \(newTimeline.count) timeline rows, \(words.count) word rows, \(pageRows.count) page rows"
            )
        } catch {
            logger.error(
                "PDFReadAlongController.load failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Resolver queries

    /// Returns the active block ID and optional word index for the given playback time.
    /// Pass `currentTrackChapterIndices` and `currentTrackSegmentKey` exactly as
    /// `ReaderTab` computes them from `PlayerModel` (nil = whole-book/no-scope).
    func activeBlock(
        at time: TimeInterval,
        currentTrackSegmentKey: String? = nil,
        currentTrackChapterIndices: Set<Int>? = nil
    ) -> (blockID: String, wordIndex: Int?)? {
        guard isLoaded else { return nil }
        guard
            let blockID = ReaderActiveBlockResolver.activeBlockID(
                in: timelineCache,
                time: time,
                currentTrackSegmentKey: currentTrackSegmentKey,
                currentTrackChapterIndices: currentTrackChapterIndices)
        else { return nil }

        let wordIdx = ReaderActiveBlockResolver.activeWord(
            in: wordCache, time: time, activeBlockID: blockID)
        return (blockID: blockID, wordIndex: wordIdx)
    }

    /// Returns the 0-based PDF page index for the given block, or nil if not captured.
    func pageIndex(forBlock blockID: String) -> Int? {
        pageIndexByBlockID[blockID]
    }

    /// Returns the text of the word at `wordIndex` within `blockID`'s text, or nil.
    /// Uses `WordTokenizer.wordRanges` — same boundary definition as karaoke.
    func wordText(blockID: String, wordIndex: Int) -> String? {
        guard let text = blockTextByID[blockID] else { return nil }
        let ranges = WordTokenizer.wordRanges(in: text)
        guard ranges.indices.contains(wordIndex) else { return nil }
        return String(text[ranges[wordIndex]])
    }
}
