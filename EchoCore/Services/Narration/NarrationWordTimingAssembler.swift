// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Concatenates per-chunk word timings into one block's file-relative word
/// timings. A block is synthesized as one or more chunks; this rebases each
/// chunk's 0-based `wordIndex` by the running word count and shifts its times by
/// the chunk's start offset in the chapter audio file.
///
/// All-or-nothing per block: if any chunk lacks timings (the duration head
/// failed or a sub-chunk was skipped), the whole block returns `nil` so the
/// caller keeps that block's interpolated rows. Pure and unit-testable.
enum NarrationWordTimingAssembler {
    static func assemble(
        _ chunks: [(timings: [ChunkWordTiming]?, startInFile: TimeInterval)]
    ) -> [ChunkWordTiming]? {
        var out: [ChunkWordTiming] = []
        var wordBase = 0
        for chunk in chunks {
            guard let timings = chunk.timings else { return nil }
            for t in timings {
                out.append(
                    ChunkWordTiming(
                        wordIndex: wordBase + t.wordIndex,
                        start: t.start + chunk.startInFile,
                        end: t.end + chunk.startInFile))
            }
            wordBase += timings.count
        }
        return out.isEmpty ? nil : out
    }
}
