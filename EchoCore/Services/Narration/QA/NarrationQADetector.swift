// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, deterministic heard-vs-source divergence detector for generated
/// narration. Reuses the alignment engine (`TokenDTW`) so the issue *set* is
/// device-independent: same source blocks + same heard words -> same windows.
/// Classification (which kind of issue, suggested fixes) is a separate step.
enum NarrationQADetector {
    static func detect(
        expectedBlocks: [(blockID: String, text: String)],
        heardWords: [TranscribedWord],
        audiobookID: String
    ) -> [DivergenceWindow] {
        guard !expectedBlocks.isEmpty, !heardWords.isEmpty else { return [] }

        // Build EPUB tokens + a per-token map back to (blockID, sourceWordIndex).
        var epubTokens: [TokenDTW.EPubToken] = []
        // token position -> (blockID, sourceWordIndex)
        var tokenOrigin: [(blockID: String, wordIndex: Int)] = []
        // blockID -> [sourceWordIndex -> source word string], for window text.
        var blockWords: [String: [String]] = [:]
        for block in expectedBlocks {
            let words = WordTokenizer.words(in: block.text).map(String.init)
            blockWords[block.blockID] = words
            for (wordIndex, word) in words.enumerated() {
                for norm in TokenDTW.normalize(word) {
                    epubTokens.append(TokenDTW.EPubToken(text: norm, blockID: block.blockID))
                    tokenOrigin.append((block.blockID, wordIndex))
                }
            }
        }
        guard !epubTokens.isEmpty else { return [] }

        let audioTokens: [TokenDTW.AudioToken] = heardWords.flatMap { hw in
            TokenDTW.normalize(hw.text).map { TokenDTW.AudioToken(text: $0, time: hw.start) }
        }
        guard !audioTokens.isEmpty else { return [] }

        let matches = TokenDTW.wordMatchesWithBisection(epub: epubTokens, audio: audioTokens)

        // Covered source words per block, and the audio time for each.
        var coveredWords: [String: Set<Int>] = [:]
        var matchAudioTimes: [String: [Int: TimeInterval]] = [:]
        for m in matches {
            coveredWords[m.blockID, default: []].insert(m.wordIndexInBlock)
            matchAudioTimes[m.blockID, default: [:]][m.wordIndexInBlock] = m.audioTime
        }

        var windows: [DivergenceWindow] = []
        for block in expectedBlocks {
            guard let words = blockWords[block.blockID], !words.isEmpty else { continue }
            // A source word is "reportable" only if it contributed at least one
            // normalized token (i.e. it could ever match). Words that normalize to
            // empty ("a", "I", punctuation) are never flagged.
            let reportable = Set(
                tokenOrigin.filter { $0.blockID == block.blockID }.map { $0.wordIndex })
            let covered = coveredWords[block.blockID] ?? []
            let times = matchAudioTimes[block.blockID] ?? [:]

            var run: [Int] = []
            func flush() {
                guard let first = run.first, let last = run.last else { return }
                let start = nearestTime(before: first, in: times) ?? times.values.min() ?? 0
                let end = nearestTime(after: last, in: times) ?? times.values.max() ?? start
                let expected = words[first...last].joined(separator: " ")
                windows.append(
                    DivergenceWindow(
                        blockID: block.blockID,
                        expectedText: expected,
                        heardText: "",
                        expectedWordStart: first,
                        expectedWordEnd: last,
                        audioStart: start,
                        audioEnd: max(end, start),
                        confidence: 1.0))
                run = []
            }
            for idx in words.indices {
                let isGap = reportable.contains(idx) && !covered.contains(idx)
                if isGap {
                    run.append(idx)
                } else {
                    flush()
                }
            }
            flush()
        }
        return windows
    }

    private static func nearestTime(before index: Int, in times: [Int: TimeInterval])
        -> TimeInterval?
    {
        times.keys.filter { $0 < index }.max().flatMap { times[$0] }
    }

    private static func nearestTime(after index: Int, in times: [Int: TimeInterval])
        -> TimeInterval?
    {
        times.keys.filter { $0 > index }.min().flatMap { times[$0] }
    }
}
