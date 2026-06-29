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
}
