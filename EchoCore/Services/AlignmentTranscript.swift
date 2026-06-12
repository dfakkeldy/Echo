import Foundation

@preconcurrency import WhisperKit

/// A single transcribed word with its absolute audio-file timestamp.
///
/// Produced by `AlignmentTranscript.words(from:captureStart:)` — the bridge
/// between WhisperKit's per-window `TranscriptionResult`s and the alignment
/// pipeline's token stream. `start` is absolute audio-file time (the capture's
/// start offset is already applied), so downstream consumers never deal with
/// window- or chunk-relative clocks.
struct TranscribedWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
}

/// Flattens WhisperKit transcription output into a time-ordered word stream.
enum AlignmentTranscript {

    /// Collects every word timing from every `TranscriptionResult`.
    ///
    /// With `chunkingStrategy: .vad`, WhisperKit returns one result per
    /// internal audio window — all of them carry text, and their segment and
    /// word timings are already seek-adjusted to the capture's clock.
    ///
    /// Word timings are preferred. Segments without word data fall back to
    /// spreading the segment's whitespace-separated words evenly across the
    /// segment's own time bounds, which caps the timing error at one segment
    /// (≤30 s of audio) rather than one capture.
    ///
    /// - Parameters:
    ///   - results: Raw output of `WhisperKit.transcribe(audioArrays:)` for a
    ///     single capture (the outer array has one entry per input array).
    ///   - captureStart: Absolute audio-file time of the capture's first sample.
    /// - Returns: Words ordered by start time, with absolute timestamps.
    static func words(
        from results: [[TranscriptionResult]?],
        captureStart: TimeInterval
    ) -> [TranscribedWord] {
        let segments = results
            .compactMap { $0 }
            .flatMap { $0 }
            .flatMap { $0.segments }
            .sorted { $0.start < $1.start }

        var collected: [TranscribedWord] = []
        for segment in segments {
            if let timings = segment.words, !timings.isEmpty {
                for timing in timings {
                    let text = clean(timing.word)
                    guard !text.isEmpty else { continue }
                    collected.append(TranscribedWord(
                        text: text,
                        start: captureStart + TimeInterval(timing.start)
                    ))
                }
            } else {
                // No word-level data: spread the segment's words evenly
                // across the segment's own bounds.
                let texts = clean(segment.text)
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                guard !texts.isEmpty else { continue }
                let step = TimeInterval(segment.end - segment.start) / Double(texts.count)
                for (index, text) in texts.enumerated() {
                    collected.append(TranscribedWord(
                        text: text,
                        start: captureStart + TimeInterval(segment.start) + Double(index) * step
                    ))
                }
            }
        }
        return collected.sorted { $0.start < $1.start }
    }

    /// Back-projects a block's first-word time from a transcript that begins
    /// mid-block.
    ///
    /// When `AutoAlignmentTextMatcher` reports the transcript's best window
    /// starting `matchedBlockWindowStart` tokens into the block, the block's
    /// first word was spoken roughly that many tokens *before* the first
    /// transcribed word — at the speech rate observed in the words
    /// themselves, clamped to plausible narration bounds.
    static func projectBlockStart(
        words: [TranscribedWord],
        matchedBlockWindowStart: Int
    ) -> TimeInterval? {
        guard let first = words.first else { return nil }
        guard matchedBlockWindowStart > 0, words.count >= 3, let last = words.last else {
            return first.start
        }
        let rate = min(1.0, max(0.15, (last.start - first.start) / Double(words.count - 1)))
        return max(0, first.start - Double(matchedBlockWindowStart) * rate)
    }

    /// Transcribes raw 16 kHz mono samples and returns time-stamped words.
    ///
    /// Single home for the alignment pipeline's `DecodingOptions` — word
    /// timestamps on, VAD chunking for long captures — shared by the batch
    /// pipeline and the continuous background service.
    static func transcribeWords(
        with whisperKit: WhisperKit,
        samples: [Float],
        captureStart: TimeInterval
    ) async -> [TranscribedWord] {
        guard !samples.isEmpty else { return [] }
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            wordTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: .vad
        )
        let results = await whisperKit.transcribe(audioArrays: [samples], decodeOptions: options)
        return words(from: results, captureStart: captureStart)
    }

    /// Strips Whisper special tokens (`<|endoftext|>`, `<|nospeech|>`, …)
    /// and surrounding whitespace.
    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
