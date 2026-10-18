// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Turns the Kokoro duration head's per-token frame counts into per-word audio
/// spans. Spoken groups are runs of phoneme tokens between the space token
/// (id 16) and the BOS/EOS boundary token (id 0); an authored word is one group
/// by default, or the several `wordGroupCounts` assigns it. Frame counts are
/// normalized so the spans sum to the real audio length
/// (`sampleCount / sampleRate`), which absorbs the duration predictor's rounding
/// and any speed scaling.
///
/// Pure and deterministic — unit-tested without the model. Returns `nil` on any
/// inconsistency so the caller falls back to interpolation rather than emitting
/// wrong timings.
enum KokoroWordTimer {
    private nonisolated static let spaceTokenId: Int32 = 16
    private nonisolated static let boundaryTokenId: Int32 = KokoroPhonemeVocab.boundaryTokenId  // 0

    /// `wordGroupCounts` gives the number of spoken groups each authored word
    /// owns, in reading order, so a word spoken as more than one group (an
    /// intra-word hyphen, a CamelCase compound) keeps a single span covering all
    /// of them instead of inflating the group count and costing the whole chunk
    /// its timings. Pass `nil` when the mapping is unproven — that keeps the
    /// historical one-group-per-word reading.
    nonisolated static func wordTimings(
        ids: [Int32], perTokenFrames: [Float], wordCount: Int,
        wordGroupCounts: [Int]? = nil,
        sampleCount: Int, sampleRate: Double
    ) -> [ChunkWordTiming]? {
        guard
            ids.count == perTokenFrames.count, !ids.isEmpty,
            wordCount > 0, sampleCount > 0, sampleRate > 0
        else { return nil }

        let totalFrames = perTokenFrames.reduce(0, +)
        guard totalFrames > 0 else { return nil }
        let secondsPerFrame = (Double(sampleCount) / sampleRate) / Double(totalFrames)

        var groups: [(start: Double, end: Double)] = []
        var cumulative: Double = 0
        var wordStart: Double?
        var wordEnd: Double = 0

        func closeWord() {
            if let s = wordStart {
                groups.append((s, wordEnd))
                wordStart = nil
            }
        }

        for (i, id) in ids.enumerated() {
            let f = Double(perTokenFrames[i])
            let tStart = cumulative * secondsPerFrame
            let tEnd = (cumulative + f) * secondsPerFrame
            cumulative += f
            if id == boundaryTokenId || id == spaceTokenId {
                closeWord()  // boundary/space ends a word; its own span is inter-word gap
                continue
            }
            if wordStart == nil { wordStart = tStart }
            wordEnd = tEnd
        }
        closeWord()

        // One group per authored word unless the plan proved otherwise. Both the
        // per-word counts and their total are checked, so a grouping that doesn't
        // account for exactly these groups falls back to interpolation rather
        // than shifting every later word onto the wrong audio.
        let groupsPerWord = wordGroupCounts ?? Array(repeating: 1, count: wordCount)
        guard groupsPerWord.count == wordCount,
            groupsPerWord.allSatisfy({ $0 > 0 }),
            groupsPerWord.reduce(0, +) == groups.count
        else { return nil }

        var timings: [ChunkWordTiming] = []
        timings.reserveCapacity(wordCount)
        var groupIndex = 0
        for (wordIndex, groupCount) in groupsPerWord.enumerated() {
            // A word spoken as several groups spans the break between them; that
            // silence is part of the word (the hyphen in "well-tempered"), not an
            // inter-word gap.
            timings.append(
                ChunkWordTiming(
                    wordIndex: wordIndex,
                    start: groups[groupIndex].start,
                    end: groups[groupIndex + groupCount - 1].end))
            groupIndex += groupCount
        }
        return timings
    }
}
