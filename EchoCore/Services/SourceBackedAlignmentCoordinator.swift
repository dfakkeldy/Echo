// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Aligns a source-backed book's on-device ASR words (already persisted in
/// `standalone_transcript`) to its canonical EPUB/PDF source blocks.
///
/// Reuses the pure, DB-free engine the auto-alignment pipeline and
/// `MacAlignmentService` already use — `TokenDTW` + `AnchorSelector` +
/// `WordTimingMaterializer` — but takes its audio tokens from stored ASR rows
/// instead of running WhisperKit. The source `epub_block.text` is read-only:
/// alignment writes only `alignment_anchor` rows and refines `word_timing`.
enum SourceBackedAlignmentCoordinator {

    /// Visible, text-bearing source blocks in reading order, one `EPubToken`
    /// per block (text = the whole block; `TokenDTW.normalize` tokenizes it).
    static func epubTokens(
        audiobookID: String, dbService: DatabaseService
    ) throws -> [TokenDTW.EPubToken] {
        let blocks = try EPubBlockDAO(db: dbService.writer).visibleBlocks(for: audiobookID)
        return blocks.compactMap { block in
            guard let text = block.text, !text.isEmpty else { return nil }
            return TokenDTW.EPubToken(text: text, blockID: block.id)
        }
    }

    /// ASR audio tokens for the book, ordered by `(chapter_index, segment_index)`
    /// with ABSOLUTE audio-file start times, expanded through `TokenDTW.normalize`
    /// exactly as `AutoAlignmentWorker` does for live transcription.
    static func audioTokens(
        audiobookID: String, dbService: DatabaseService
    ) throws -> [TokenDTW.AudioToken] {
        let segments = try dbService.writer.read { db in
            try StandaloneTranscriptRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("chapter_index"), Column("segment_index"))
                .fetchAll(db)
        }
        let decoder = JSONDecoder()
        var tokens: [TokenDTW.AudioToken] = []
        for segment in segments {
            guard
                let json = segment.wordsJSON,
                let data = json.data(using: .utf8),
                let words = try? decoder.decode([StandaloneTranscribedWord].self, from: data)
            else { continue }
            for word in words {
                let tw = TranscribedWord(text: word.word, start: word.start)
                tokens.append(
                    contentsOf: TokenDTW.normalize(tw.text).map {
                        TokenDTW.AudioToken(text: $0, time: tw.start)
                    })
            }
        }
        return tokens
    }

    /// Source value stamped on every anchor this coordinator writes — the
    /// queryable identity used to clear only its own anchors on re-run.
    static let anchorSource = AlignmentAnchorRecord.Source.transcriptAlignment.rawValue

    /// Aligns the book's persisted ASR to its source blocks, writes
    /// `.transcriptAlignment` anchors (replacing only prior ones of that
    /// source), and refines `word_timing` from the DTW word matches. No-ops
    /// quietly when there is nothing to align (no source tokens, no audio
    /// tokens, or no selectable anchors) so a partial book is safe to re-run.
    static func align(audiobookID: String, dbService: DatabaseService) async throws {
        let epub = try epubTokens(audiobookID: audiobookID, dbService: dbService)
        let audio = try audioTokens(audiobookID: audiobookID, dbService: dbService)
        guard !epub.isEmpty, !audio.isEmpty else { return }

        let candidates = TokenDTW.alignWithBisection(epub: epub, audio: audio)
        let selected = AnchorSelector.select(candidates: candidates)

        // Always clear our own prior anchors first so a re-run that now selects
        // fewer (or zero) anchors converges instead of leaving stale rows.
        let anchorDAO = AlignmentAnchorDAO(db: dbService.writer)
        _ = try anchorDAO.deleteAnchors(for: audiobookID, source: anchorSource)

        guard !selected.isEmpty else { return }

        let now = AlignmentService.isoFormatter.string(from: Date())
        let records = selected.map { candidate in
            AlignmentAnchorRecord(
                id: UUID().uuidString, audiobookID: audiobookID,
                epubBlockID: candidate.blockID, audioTime: candidate.time,
                audioEndTime: nil,
                anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: anchorSource,
                note: "Source-backed transcript alignment (TokenDTW + AnchorSelector)",
                createdAt: now, modifiedAt: nil)
        }

        // `insertAnchors` recalculates the timeline AND materializes interpolated
        // word timings (materializeWordTimings: true by default), so the refine
        // step below has interpolated rows to override.
        let service = AlignmentService(db: dbService.writer, audiobookID: audiobookID)
        try service.insertAnchors(records)

        // Override matched words with their DTW-derived audio times.
        let matches = TokenDTW.wordMatchesWithBisection(epub: epub, audio: audio)
        let matchesByBlock = Dictionary(grouping: matches, by: { $0.blockID })
        try WordTimingMaterializer.refine(
            audiobookID: audiobookID, dtwMatchesByBlock: matchesByBlock, writer: dbService.writer)
    }

    /// Number of `word_timing` rows for the book whose confidence is below
    /// `threshold` — the spans that stayed interpolated (0.5) rather than being
    /// retimed by a real DTW audio match (0.85). Callers/debug UI use this to
    /// flag likely-misaligned regions; the default 0.75 separates the two.
    static func lowConfidenceWordCount(
        audiobookID: String, dbService: DatabaseService, threshold: Double = 0.75
    ) throws -> Int {
        let words = try WordTimingDAO(db: dbService.writer).words(forAudiobook: audiobookID)
        return words.filter { $0.confidence < threshold }.count
    }
}
