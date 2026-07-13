// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationRenderPlan: Equatable, Sendable {
    let blocks: [NarrationPlannedBlock]

    var pronunciationAuditDiagnostics: [PronunciationAuditDiagnostic] {
        blocks.flatMap(\.pronunciationAuditDiagnostics)
    }
}

struct NarrationPreparedBlock: Equatable, Sendable {
    let block: EPubBlockRecord
    let pronunciationDecisionSeeds: [PronunciationDecisionSeed]
}

struct NarrationPlannedBlock: Equatable, Sendable {
    let blockID: String
    let originalBlock: EPubBlockRecord
    let synthesisChunks: [PlannedSynthesisChunk]
    let pronunciationDecisions: [PronunciationAuditDecision]
    let trailingSilence: NarrationPlannedSilence?

    var isSpeakable: Bool { !synthesisChunks.isEmpty }

    var pronunciationAuditDiagnostics: [PronunciationAuditDiagnostic] {
        synthesisChunks.enumerated().compactMap { chunkIndex, chunk in
            guard
                case let .mismatch(expectedDisplayText, reconstructedSpokenSurface) =
                    chunk.pronunciationEvidenceValidation
            else { return nil }

            return PronunciationAuditDiagnostic(
                reason: .spokenSurfaceMismatch,
                blockID: blockID,
                chunkIndex: chunkIndex,
                expectedDisplayText: expectedDisplayText,
                reconstructedSpokenSurface: reconstructedSpokenSurface,
                fallbackHits: chunk.pronunciationFallbackHits)
        }
    }
}

enum NarrationPlannedSilence: Equatable, Sendable {
    case paragraph
    case heading
    case sectionBreak

    var duration: TimeInterval {
        switch self {
        case .paragraph:
            return 0.18
        case .heading:
            return 0.35
        case .sectionBreak:
            return 0.85
        }
    }
}

enum NarrationRenderPlanner {
    static func make(
        blocks: [EPubBlockRecord],
        overrides: PronunciationOverrides,
        maxChars: Int = 350,
        maxPhonemes: Int = 420
    ) throws -> NarrationRenderPlan {
        try make(
            preparedBlocks: blocks.map {
                NarrationPreparedBlock(block: $0, pronunciationDecisionSeeds: [])
            },
            overrides: overrides,
            maxChars: maxChars,
            maxPhonemes: maxPhonemes)
    }

    static func make(
        preparedBlocks: [NarrationPreparedBlock],
        overrides: PronunciationOverrides,
        maxChars: Int = 350,
        maxPhonemes: Int = 420
    ) throws -> NarrationRenderPlan {
        // One planner owns the single `KokoroG2P` (and its ~12 MB lexicon) for
        // this render unit; the chunker sizes splits via its phoneme count.
        let pronunciationPlanner = try PronunciationPlanner()
        let resolvedPhonemeCount = pronunciationPlanner.phonemeCount(for:)
        let candidates = preparedBlocks.filter { preparedBlock in
            let block = preparedBlock.block
            guard block.text?.isEmpty == false else { return false }
            return !block.isHidden
        }

        var planned: [NarrationPlannedBlock] = []
        for preparedBlock in candidates {
            let block = preparedBlock.block
            let normalized = TextNormalizer.normalize(block.text ?? "")
            if isDecorativeSeparator(normalized) {
                planned.append(
                    NarrationPlannedBlock(
                        blockID: block.id,
                        originalBlock: block,
                        synthesisChunks: [],
                        pronunciationDecisions: [],
                        trailingSilence: .sectionBreak))
                continue
            }

            let overrideResult = overrides.rewrite(to: normalized, blockID: block.id)
            let homographResult = HomographPronunciationResolver.rewrite(
                to: overrideResult.text,
                blockID: block.id)
            var decisionSeeds = uniqueDecisionSeeds(
                preparedBlock.pronunciationDecisionSeeds
                    + overrideResult.decisionSeeds
                    + homographResult.decisionSeeds)
            let resolved = homographResult.text
            let blockDisplayText = MisakiPronunciationMarkup.displayText(from: resolved)
            let fragments = NarrationTextChunker.splitResolved(
                resolved,
                maxPhonemes: maxPhonemes,
                phonemeCount: resolvedPhonemeCount)
            var synthesisChunks: [PlannedSynthesisChunk] = []
            var wordBase = 0
            for fragment in fragments {
                let chunk = try pronunciationPlanner.planResolved(fragment)
                let tokenDecisionSeeds = chunk.pronunciationTokenEvidence.compactMap { evidence in
                    PronunciationAuditContext.decisionSeed(
                        for: evidence,
                        blockID: block.id,
                        chunkDisplayText: chunk.displayText,
                        blockDisplayText: blockDisplayText,
                        wordBase: wordBase)
                }
                // Explicit rewrite-stage decisions remain first so they win any
                // collision with evidence emitted by the final G2P pass.
                decisionSeeds = uniqueDecisionSeeds(decisionSeeds + tokenDecisionSeeds)
                synthesisChunks.append(chunk)
                wordBase += chunk.wordCount
            }
            let pronunciationDecisions = try decisionSeeds.map { seed in
                seed.materialized(
                    kokoroTokenIDs: try pronunciationPlanner.phonemeIDs(
                        forIPA: seed.selectedIPA))
            }
            planned.append(
                NarrationPlannedBlock(
                    blockID: block.id,
                    originalBlock: block,
                    synthesisChunks: synthesisChunks,
                    pronunciationDecisions: pronunciationDecisions,
                    trailingSilence: nil))
        }

        return NarrationRenderPlan(blocks: attachTrailingSilences(to: planned))
    }

    private static func attachTrailingSilences(
        to blocks: [NarrationPlannedBlock]
    ) -> [NarrationPlannedBlock] {
        guard !blocks.isEmpty else { return [] }
        let lastSpeakableIndex = blocks.lastIndex(where: \.isSpeakable)
        return blocks.enumerated().map { index, block in
            if block.trailingSilence == .sectionBreak { return block }
            guard block.isSpeakable, index != lastSpeakableIndex else { return block }
            let nextIsSectionBreak =
                index + 1 < blocks.count
                && blocks[index + 1].trailingSilence == .sectionBreak
            guard !nextIsSectionBreak else { return block }
            let silence: NarrationPlannedSilence =
                isHeading(block.originalBlock) ? .heading : .paragraph
            return NarrationPlannedBlock(
                blockID: block.blockID,
                originalBlock: block.originalBlock,
                synthesisChunks: block.synthesisChunks,
                pronunciationDecisions: block.pronunciationDecisions,
                trailingSilence: silence)
        }
    }

    private static func uniqueDecisionSeeds(
        _ seeds: [PronunciationDecisionSeed]
    ) -> [PronunciationDecisionSeed] {
        struct Span: Hashable {
            let blockID: String
            let wordStart: Int
            let wordEnd: Int
        }

        var seen: Set<Span> = []
        return seeds.filter { seed in
            seen.insert(
                Span(
                    blockID: seed.blockID,
                    wordStart: seed.wordStart,
                    wordEnd: seed.wordEnd)
            ).inserted
        }.sorted { lhs, rhs in
            if lhs.wordStart != rhs.wordStart { return lhs.wordStart < rhs.wordStart }
            return lhs.wordEnd < rhs.wordEnd
        }
    }

    private static func isHeading(_ block: EPubBlockRecord) -> Bool {
        block.blockKind.localizedCaseInsensitiveContains("heading")
            || block.blockKind.localizedCaseInsensitiveContains("title")
    }

    private static func isDecorativeSeparator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { $0.isLetter || $0.isNumber }) { return false }
        let allowed = CharacterSet(charactersIn: "*-~•·. _")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
