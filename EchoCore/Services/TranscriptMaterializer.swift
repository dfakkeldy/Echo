// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Projects an audio-only book's raw ASR rows (`standalone_transcript`) into the
/// canonical reader tables so the existing read-along reader (highlight, search,
/// tap-to-seek, study anchoring) drives it unchanged. The raw rows are retained
/// as the audit copy; these projected rows are the reader projection.
///
/// Each VAD segment becomes one paragraph `epub_block`, one timestamped
/// `timeline_item`, and one `word_timing` row per ASR word (real start/end times,
/// not interpolated). Block text is the ASR words joined by single spaces, so its
/// `WordTokenizer` token sequence is 1:1 with `words_json` — the reader's word
/// highlight lands on the right token.
///
/// Idempotent: deletes this book's `transcript-%` projection before rewrite, so
/// re-transcribe converges to a single clean copy.
enum TranscriptMaterializer {
    static func materialize(audiobookID: String, writer: DatabaseWriter) throws {
        let segments = try writer.read { db in
            try StandaloneTranscriptRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("chapter_index"), Column("segment_index"))
                .fetchAll(db)
        }

        try deleteProjection(audiobookID: audiobookID, writer: writer)
        guard !segments.isEmpty else { return }

        var blocks: [EPubBlockRecord] = []
        var items: [TimelineItem] = []
        var wordTimings: [WordTimingRecord] = []
        let now = ISO8601DateFormatter().string(from: Date())

        for (sequence, segment) in segments.enumerated() {
            let asrWords = decodeWords(segment.wordsJSON)
            let blockText =
                asrWords.isEmpty
                ? segment.text
                : asrWords.map(\.word).joined(separator: " ")
            let blockID =
                "transcript-\(audiobookID)-c\(segment.chapterIndex)-s\(segment.segmentIndex)"

            blocks.append(
                EPubBlockRecord(
                    id: blockID,
                    audiobookID: audiobookID,
                    spineHref: "transcript",
                    spineIndex: segment.chapterIndex,
                    blockIndex: segment.segmentIndex,
                    sequenceIndex: sequence,
                    blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                    text: blockText,
                    htmlContent: nil,
                    cardColor: nil,
                    chapterThemeColor: nil,
                    imagePath: nil,
                    chapterIndex: segment.chapterIndex,
                    isHidden: false,
                    hiddenReason: nil,
                    wordCount: WordTokenizer.words(in: blockText).count,
                    markers: nil,
                    textFormats: nil,
                    createdAt: now,
                    modifiedAt: nil))

            items.append(
                TimelineItem(
                    id: "epub-\(blockID)",
                    audiobookID: audiobookID,
                    itemType: .textSegment,
                    title: blockText,
                    subtitle: nil,
                    textPayload: blockText,
                    imagePath: nil,
                    audioStartTime: segment.startTime,
                    audioEndTime: segment.endTime,
                    epubSequenceIndex: sequence,
                    granularityLevel: .paragraph,
                    playlistPosition: nil,
                    isEnabled: true,
                    sourceTable: "standalone_transcript",
                    sourceRowid: segment.id,
                    metadataJSON: nil,
                    epubBlockID: blockID,
                    timestampSource: TimestampSource.transcript.rawValue,
                    alignmentStatus: AlignmentStatus.lockedAnchor.rawValue,
                    alignmentConfidence: nil,
                    createdAt: now,
                    modifiedAt: nil))

            // word_index is the position over WordTokenizer of the block text.
            // Because blockText joins the ASR words by single spaces, that token
            // sequence is identical to asrWords — so the JSON index IS the
            // tokenizer index. Enforce the invariant by zipping against the
            // tokenizer so a stray space in an ASR word can't desync the highlight.
            let tokens = WordTokenizer.words(in: blockText)
            for (index, asr) in asrWords.enumerated() where index < tokens.count {
                wordTimings.append(
                    WordTimingRecord(
                        audiobookID: audiobookID,
                        epubBlockID: blockID,
                        wordIndex: index,
                        word: String(tokens[index]),
                        audioStartTime: asr.start,
                        audioEndTime: asr.end,
                        confidence: Double(asr.confidence),
                        source: "transcript"))
            }
        }

        try EPubBlockDAO(db: writer).insertAll(blocks)
        try TimelineDAO(db: writer).ingest(items)
        try WordTimingDAO(db: writer).insert(wordTimings)
    }

    private static func decodeWords(_ json: String?) -> [StandaloneTranscribedWord] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([StandaloneTranscribedWord].self, from: data)) ?? []
    }

    /// Deletes only THIS book's transcript projection (prefix-scoped to the book
    /// id), never an EPUB/PDF book's canonical rows.
    private static func deleteProjection(audiobookID: String, writer: DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM word_timing
                    WHERE audiobook_id = ? AND epub_block_id LIKE 'transcript-%'
                    """, arguments: [audiobookID])
            try db.execute(
                sql: """
                    DELETE FROM timeline_item
                    WHERE audiobook_id = ? AND source_table = 'standalone_transcript'
                    """, arguments: [audiobookID])
            try db.execute(
                sql: """
                    DELETE FROM epub_block
                    WHERE audiobook_id = ? AND id LIKE 'transcript-%'
                    """, arguments: [audiobookID])
        }
    }
}
