// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationRenderPlan: Equatable, Sendable {
    let blocks: [NarrationPlannedBlock]
}

struct NarrationPlannedBlock: Equatable, Sendable {
    let blockID: String
    let originalBlock: EPubBlockRecord
    let speechSegments: [String]
    let trailingSilence: NarrationPlannedSilence?

    var isSpeakable: Bool { !speechSegments.isEmpty }
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
        maxChars: Int = 350
    ) -> NarrationRenderPlan {
        let candidates = blocks.filter { block in
            guard block.text?.isEmpty == false else { return false }
            return !block.isHidden
        }

        var planned: [NarrationPlannedBlock] = []
        for block in candidates {
            let normalized = TextNormalizer.normalize(block.text ?? "")
            if isDecorativeSeparator(normalized) {
                planned.append(
                    NarrationPlannedBlock(
                        blockID: block.id,
                        originalBlock: block,
                        speechSegments: [],
                        trailingSilence: .sectionBreak))
                continue
            }

            let rewritten = HomographPronunciationResolver.apply(to: overrides.apply(to: normalized))
            let speech = NarrationTextChunker.split(rewritten, maxChars: maxChars)
            planned.append(
                NarrationPlannedBlock(
                    blockID: block.id,
                    originalBlock: block,
                    speechSegments: speech,
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
            let nextIsSectionBreak = index + 1 < blocks.count
                && blocks[index + 1].trailingSilence == .sectionBreak
            guard !nextIsSectionBreak else { return block }
            let silence: NarrationPlannedSilence =
                isHeading(block.originalBlock) ? .heading : .paragraph
            return NarrationPlannedBlock(
                blockID: block.blockID,
                originalBlock: block.originalBlock,
                speechSegments: block.speechSegments,
                trailingSilence: silence)
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
