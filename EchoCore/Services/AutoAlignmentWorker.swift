// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Pure per-chapter auto-alignment work that must not inherit
/// `AutoAlignmentService`'s `@MainActor` isolation.
nonisolated enum AutoAlignmentWorker {
    struct AlignmentBlock: Sendable, Equatable {
        let id: String
        let text: String?
        let isHidden: Bool
    }

    struct Input: Sendable {
        let words: [TranscribedWord]
        let alignmentBlocks: [AlignmentBlock]
        let anchoredBlockIDs: Set<String>
        let windowStart: TimeInterval
        let windowEnd: TimeInterval
        let lastGlobalAnchorTime: TimeInterval
        let minAnchorRunLength: Int
    }

    struct Output: Sendable, Equatable {
        let selectedCandidates: [TokenDTW.AnchorCandidate]
        let wordMatchesByBlock: [String: [TokenDTW.WordMatch]]
        let wordCount: Int
        let audioTokenCount: Int
        let epubTokenCount: Int
        let candidateCount: Int
    }

    private static let signposter = OSSignposter(
        subsystem: "com.echo.autoalignment",
        category: "AutoAlignmentWorker"
    )

    /// Tokenizes transcript/EPUB text, runs DTW, emits grouped word matches,
    /// and applies the pure anchor gates on the global concurrent executor.
    @concurrent
    nonisolated static func alignChapter(_ input: Input) async throws -> Output {
        let interval = signposter.beginInterval("ChapterAlignment")
        defer { signposter.endInterval("ChapterAlignment", interval) }

        try Task.checkCancellation()
        let audioTokens = input.words.flatMap { word in
            TokenDTW.normalize(word.text).map {
                TokenDTW.AudioToken(text: $0, time: word.start)
            }
        }

        try Task.checkCancellation()
        var epubTokens: [TokenDTW.EPubToken] = []
        for block in input.alignmentBlocks {
            guard let text = block.text, !block.isHidden else { continue }
            epubTokens += TokenDTW.normalize(text).map {
                TokenDTW.EPubToken(text: $0, blockID: block.id)
            }
        }

        try Task.checkCancellation()
        guard !audioTokens.isEmpty, !epubTokens.isEmpty else {
            return Output(
                selectedCandidates: [],
                wordMatchesByBlock: [:],
                wordCount: input.words.count,
                audioTokenCount: audioTokens.count,
                epubTokenCount: epubTokens.count,
                candidateCount: 0
            )
        }

        let candidates = try await TokenDTW.alignWithBisectionCancellable(
            epub: epubTokens,
            audio: audioTokens
        )

        try Task.checkCancellation()
        let chapterWordMatches = try await TokenDTW.wordMatchesWithBisectionCancellable(
            epub: epubTokens,
            audio: audioTokens
        )
        let wordMatchesByBlock = Dictionary(grouping: chapterWordMatches, by: \.blockID)

        try Task.checkCancellation()
        let eligible = candidates.filter { candidate in
            !input.anchoredBlockIDs.contains(candidate.blockID)
                && candidate.time >= input.windowStart
                && candidate.time <= input.windowEnd
                && candidate.time + 0.25 >= input.lastGlobalAnchorTime
        }
        let selected = AnchorSelector.select(
            candidates: eligible,
            minRunLength: input.minAnchorRunLength
        )

        try Task.checkCancellation()
        return Output(
            selectedCandidates: selected,
            wordMatchesByBlock: wordMatchesByBlock,
            wordCount: input.words.count,
            audioTokenCount: audioTokens.count,
            epubTokenCount: epubTokens.count,
            candidateCount: candidates.count
        )
    }
}
