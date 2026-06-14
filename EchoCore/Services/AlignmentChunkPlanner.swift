import Foundation

/// Plans transcription capture windows for one audiobook chapter.
///
/// Chunks prefer to end at detected-silence midpoints (clean word boundaries)
/// but are always hard-capped: a chapter with no usable silences still gets
/// bounded chunks instead of one chapter-length capture, which kept memory
/// and WhisperKit input sizes unbounded in the previous implementation.
enum AlignmentChunkPlanner {

    struct Chunk: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    /// Splits `[chapterStart, chapterEnd]` into contiguous capture chunks.
    ///
    /// - Cuts at the latest silence midpoint within `(cursor+minChunk,
    ///   cursor+maxChunk]`; falls back to a hard cut at `cursor+maxChunk`
    ///   when no silence is in reach.
    /// - A trailing remainder shorter than 5 s merges into the previous chunk
    ///   (slightly exceeding `maxChunk` is acceptable there).
    static func plan(
        chapterStart: TimeInterval,
        chapterEnd: TimeInterval,
        silences: [SilenceDetectionService.SilenceGaps],
        minChunk: TimeInterval = 15,
        maxChunk: TimeInterval = 45
    ) -> [Chunk] {
        guard chapterEnd > chapterStart else { return [] }
        let minTail: TimeInterval = 5

        let midpoints =
            silences
            .map { ($0.start + $0.end) / 2 }
            .filter { $0 > chapterStart && $0 < chapterEnd }
            .sorted()

        var chunks: [Chunk] = []
        var cursor = chapterStart
        while chapterEnd - cursor > maxChunk {
            let windowStart = cursor + minChunk
            let windowEnd = cursor + maxChunk
            let cut = midpoints.last { $0 > windowStart && $0 <= windowEnd } ?? windowEnd
            chunks.append(Chunk(start: cursor, end: cut))
            cursor = cut
        }

        if chapterEnd - cursor < minTail, let previous = chunks.popLast() {
            chunks.append(Chunk(start: previous.start, end: chapterEnd))
        } else {
            chunks.append(Chunk(start: cursor, end: chapterEnd))
        }
        return chunks
    }
}
