// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, deterministic heard-vs-source divergence detector for generated
/// narration. Reuses the alignment engine (`TokenDTW`) so the issue *set* is
/// device-independent: same source blocks + same heard words -> same windows.
/// Classification (which kind of issue, suggested fixes) is a separate step.
nonisolated enum NarrationQADetector {
    private static let lowConfidenceThreshold = 0.5

    static func detect(
        expectedBlocks: [(blockID: String, text: String)],
        heardWords: [TranscribedWord]
    ) -> [DivergenceWindow] {
        guard !expectedBlocks.isEmpty, !heardWords.isEmpty else { return [] }

        // Build EPUB tokens + a per-token map back to (blockID, sourceWordIndex).
        var epubTokens: [TokenDTW.EPubToken] = []
        // token position -> (blockID, sourceWordIndex)
        var tokenOrigin: [(blockID: String, wordIndex: Int)] = []
        // blockID -> [sourceWordIndex -> source word string], for window text.
        var blockWords: [String: [String]] = [:]
        var sourceWordGlobalIndexByBlock: [String: [Int: Int]] = [:]
        var nextSourceGlobalIndex = 0
        // blockID -> [perBlockTokenOrdinal: sourceWordIndex]. TokenDTW numbers the
        // normalized tokens 0,1,2,… within each block, but a source word can emit
        // several tokens (numbers, hyphenates) or none ("a", "I", punctuation), so
        // the token ordinal and the source-word index diverge. This map translates
        // a match's per-block token ordinal back into source-word space.
        var blockTokenWordIndex: [String: [Int]] = [:]
        for block in expectedBlocks {
            let words = WordTokenizer.words(in: block.text).map(String.init)
            blockWords[block.blockID] = words
            sourceWordGlobalIndexByBlock[block.blockID] = Dictionary(
                uniqueKeysWithValues: words.indices.map { wordIndex in
                    defer { nextSourceGlobalIndex += 1 }
                    return (wordIndex, nextSourceGlobalIndex)
                })
            var tokenWordIndex: [Int] = []
            for (wordIndex, word) in words.enumerated() {
                for norm in TokenDTW.normalize(word) {
                    epubTokens.append(TokenDTW.EPubToken(text: norm, blockID: block.blockID))
                    tokenOrigin.append((block.blockID, wordIndex))
                    tokenWordIndex.append(wordIndex)
                }
            }
            blockTokenWordIndex[block.blockID] = tokenWordIndex
        }
        guard !epubTokens.isEmpty else { return [] }

        var audioTokens: [TokenDTW.AudioToken] = []
        var audioTokenWordIndex: [Int] = []
        for (wordIndex, heardWord) in heardWords.enumerated() {
            for token in TokenDTW.normalize(heardWord.text) {
                audioTokens.append(TokenDTW.AudioToken(text: token, time: heardWord.start))
                audioTokenWordIndex.append(wordIndex)
            }
        }
        guard !audioTokens.isEmpty else { return [] }
        let reportableAudioWordIndices = Set(audioTokenWordIndex)

        let matches = TokenDTW.wordMatchesWithBisection(epub: epubTokens, audio: audioTokens)
        let audioWordIndicesByTime = audioTokens.indices.reduce(into: [TimeInterval: [Int]]()) {
            partial, tokenIndex in
            partial[audioTokens[tokenIndex].time, default: []].append(audioTokenWordIndex[tokenIndex])
        }

        // Covered source words per block, and the audio time for each.
        var coveredWords: [String: Set<Int>] = [:]
        var matchAudioTimes: [String: [Int: TimeInterval]] = [:]
        var matchAudioWordIndices: [String: [Int: Int]] = [:]
        var sourceByMatchedAudioIndex: [Int: (blockID: String, wordIndex: Int)] = [:]
        var matchedAudioIndexBySourceGlobalIndex: [Int: Int] = [:]
        for m in matches {
            // m.wordIndexInBlock is a per-block *token* ordinal; map it back to a
            // source-word index so `covered` lines up with the reporting loop below.
            guard let tokenWordIndex = blockTokenWordIndex[m.blockID],
                m.wordIndexInBlock < tokenWordIndex.count
            else { continue }
            let wordIndex = tokenWordIndex[m.wordIndexInBlock]
            coveredWords[m.blockID, default: []].insert(wordIndex)
            matchAudioTimes[m.blockID, default: [:]][wordIndex] = m.audioTime
            guard let audioWordIndex = audioWordIndicesByTime[m.audioTime]?.first else { continue }
            matchAudioWordIndices[m.blockID, default: [:]][wordIndex] = audioWordIndex
            sourceByMatchedAudioIndex[audioWordIndex] = (m.blockID, wordIndex)
            if let sourceGlobalIndex = sourceWordGlobalIndexByBlock[m.blockID]?[wordIndex],
                matchedAudioIndexBySourceGlobalIndex[sourceGlobalIndex] == nil
            {
                matchedAudioIndexBySourceGlobalIndex[sourceGlobalIndex] = audioWordIndex
            }
        }

        var windows: [DivergenceWindow] = []
        var consumedUnmatchedAudioIndices = Set<Int>()
        let matchedAudioWordIndices = Set(sourceByMatchedAudioIndex.keys)
        for block in expectedBlocks {
            guard let words = blockWords[block.blockID], !words.isEmpty else { continue }
            // A source word is "reportable" only if it contributed at least one
            // normalized token (i.e. it could ever match). Words that normalize to
            // empty ("a", "I", punctuation) are never flagged.
            let reportable = Set(
                tokenOrigin.filter { $0.blockID == block.blockID }.map { $0.wordIndex })
            let covered = coveredWords[block.blockID] ?? []
            let times = matchAudioTimes[block.blockID] ?? [:]
            let audioIndices = matchAudioWordIndices[block.blockID] ?? [:]
            let sourceGlobalIndices = sourceWordGlobalIndexByBlock[block.blockID] ?? [:]

            var run: [Int] = []
            func flush() {
                guard let first = run.first, let last = run.last else { return }
                let previousAudioIndex = sourceGlobalIndices[first].flatMap {
                    nearestMatchedAudioIndex(
                        beforeSourceIndex: $0, in: matchedAudioIndexBySourceGlobalIndex)
                }
                let nextAudioIndex = sourceGlobalIndices[last].flatMap {
                    nearestMatchedAudioIndex(
                        afterSourceIndex: $0, in: matchedAudioIndexBySourceGlobalIndex)
                }
                let heardIndices = heardWords.indices.filter {
                    !matchedAudioWordIndices.contains($0)
                        && $0 > (previousAudioIndex ?? -1)
                        && $0 < (nextAudioIndex ?? heardWords.count)
                }
                consumedUnmatchedAudioIndices.formUnion(heardIndices)
                let start = heardIndices.first.map { heardWords[$0].start }
                    ?? previousAudioIndex.map { heardWords[$0].start }
                    ?? nearestTime(before: first, in: times)
                    ?? times.values.min()
                    ?? 0
                let end = heardIndices.last.map { heardWords[$0].start }
                    ?? nextAudioIndex.map { heardWords[$0].start }
                    ?? nearestTime(after: last, in: times)
                    ?? times.values.max()
                    ?? start
                let expected = words[first...last].joined(separator: " ")
                let heardText = heardIndices.map { heardWords[$0].text }.joined(separator: " ")
                let confidence = heardIndices
                    .map { heardWords[$0].confidence }
                    .min() ?? 1.0
                windows.append(
                    DivergenceWindow(
                        blockID: block.blockID,
                        expectedText: expected,
                        heardText: heardText,
                        expectedWordStart: first,
                        expectedWordEnd: last,
                        audioStart: start,
                        audioEnd: max(end, start),
                        confidence: confidence))
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

            for sourceIndex in words.indices {
                guard let audioIndex = audioIndices[sourceIndex] else { continue }
                let heardWord = heardWords[audioIndex]
                guard heardWord.confidence < lowConfidenceThreshold else { continue }
                windows.append(
                    DivergenceWindow(
                        blockID: block.blockID,
                        expectedText: words[sourceIndex],
                        heardText: heardWord.text,
                        expectedWordStart: sourceIndex,
                        expectedWordEnd: sourceIndex,
                        audioStart: heardWord.start,
                        audioEnd: heardWord.start,
                        confidence: heardWord.confidence))
            }
        }

        windows.append(contentsOf: insertionWindows(
            heardWords: heardWords,
            reportableAudioWordIndices: reportableAudioWordIndices,
            matchedAudioWordIndices: matchedAudioWordIndices,
            consumedUnmatchedAudioIndices: consumedUnmatchedAudioIndices,
            sourceByMatchedAudioIndex: sourceByMatchedAudioIndex,
            fallbackBlockID: expectedBlocks.first?.blockID
        ))
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

    private static func nearestMatchedAudioIndex(
        beforeSourceIndex index: Int,
        in indices: [Int: Int]
    )
        -> Int?
    {
        indices.keys.filter { $0 < index }.max().flatMap { indices[$0] }
    }

    private static func nearestMatchedAudioIndex(
        afterSourceIndex index: Int,
        in indices: [Int: Int]
    )
        -> Int?
    {
        indices.keys.filter { $0 > index }.min().flatMap { indices[$0] }
    }

    private static func insertionWindows(
        heardWords: [TranscribedWord],
        reportableAudioWordIndices: Set<Int>,
        matchedAudioWordIndices: Set<Int>,
        consumedUnmatchedAudioIndices: Set<Int>,
        sourceByMatchedAudioIndex: [Int: (blockID: String, wordIndex: Int)],
        fallbackBlockID: String?
    ) -> [DivergenceWindow] {
        var windows: [DivergenceWindow] = []
        var run: [Int] = []

        func flush() {
            guard let first = run.first, let last = run.last else { return }
            guard let anchor = insertionAnchor(
                firstAudioIndex: first,
                lastAudioIndex: last,
                sourceByMatchedAudioIndex: sourceByMatchedAudioIndex,
                fallbackBlockID: fallbackBlockID
            ) else {
                run = []
                return
            }
            let heardText = run.map { heardWords[$0].text }.joined(separator: " ")
            let confidence = run.map { heardWords[$0].confidence }.min() ?? 1.0
            windows.append(
                DivergenceWindow(
                    blockID: anchor.blockID,
                    expectedText: "",
                    heardText: heardText,
                    expectedWordStart: anchor.wordIndex,
                    expectedWordEnd: anchor.wordIndex,
                    audioStart: heardWords[first].start,
                    audioEnd: heardWords[last].start,
                    confidence: confidence))
            run = []
        }

        for index in heardWords.indices {
            let isInsertion = reportableAudioWordIndices.contains(index)
                && !matchedAudioWordIndices.contains(index)
                && !consumedUnmatchedAudioIndices.contains(index)
            if isInsertion {
                run.append(index)
            } else {
                flush()
            }
        }
        flush()
        return windows
    }

    private static func insertionAnchor(
        firstAudioIndex: Int,
        lastAudioIndex: Int,
        sourceByMatchedAudioIndex: [Int: (blockID: String, wordIndex: Int)],
        fallbackBlockID: String?
    ) -> (blockID: String, wordIndex: Int)? {
        if let nextIndex = sourceByMatchedAudioIndex.keys.filter({ $0 > lastAudioIndex }).min(),
            let next = sourceByMatchedAudioIndex[nextIndex]
        {
            return next
        }
        if let previousIndex = sourceByMatchedAudioIndex.keys.filter({ $0 < firstAudioIndex }).max(),
            let previous = sourceByMatchedAudioIndex[previousIndex]
        {
            return previous
        }
        guard let fallbackBlockID else { return nil }
        return (fallbackBlockID, 0)
    }
}
