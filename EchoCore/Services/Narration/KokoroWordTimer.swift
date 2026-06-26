// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Turns the Kokoro duration head's per-token frame counts into per-word audio
/// spans. Words are runs of phoneme tokens between the space token (id 16) and
/// the BOS/EOS boundary token (id 0). Frame counts are normalized so the spans
/// sum to the real audio length (`sampleCount / sampleRate`), which absorbs the
/// duration predictor's rounding and any speed scaling.
///
/// Pure and deterministic — unit-tested without the model. Returns `nil` on any
/// inconsistency so the caller falls back to interpolation rather than emitting
/// wrong timings.
enum KokoroWordTimer {
    private static let spaceTokenId: Int32 = 16
    private static let boundaryTokenId: Int32 = KokoroPhonemeVocab.boundaryTokenId  // 0

    static func wordTimings(
        ids: [Int32], perTokenFrames: [Float], wordCount: Int,
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

        guard groups.count == wordCount else { return nil }
        return groups.enumerated().map {
            ChunkWordTiming(wordIndex: $0.offset, start: $0.element.start, end: $0.element.end)
        }
    }
}
