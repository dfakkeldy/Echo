// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Text-native planning: preserve sentence context without running Kokoro G2P
/// or publishing its pronunciation evidence. PCM stays bounded per utterance.
nonisolated enum PhononRenderPlanner {
    @concurrent
    static func make(blocks: [EPubBlockRecord]) async throws -> NarrationRenderPlan {
        var planned: [NarrationPlannedBlock] = []
        for block in blocks where !block.isHidden {
            try Task.checkCancellation()
            let text = NarrationCodeBlockCue.spokenText(for: block) ?? block.text ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let isSeparator =
                block.blockKind != EPubBlockRecord.Kind.code.rawValue
                && NarrationRenderPlanner.isDecorativeSeparator(text)
            let chunks: [PlannedSynthesisChunk] =
                isSeparator
                ? []
                : chunkTexts(text).map { text in
                    // Empty phoneme fields mean no Kokoro input/evidence exists.
                    // Phonon consumes displayText and returns no duration-head timings.
                    PlannedSynthesisChunk(
                        displayText: text, g2pInputText: text, phonemes: "", phonemeIDs: [],
                        wordCount: WordTokenizer.words(in: text).count,
                        pronunciationFallbackHits: [], pronunciationEvidenceValidation: .matched)
                }
            planned.append(
                NarrationPlannedBlock(
                    blockID: block.id, originalBlock: block, synthesisChunks: chunks,
                    pronunciationDecisions: [], pronunciationDecisionDiagnostics: [],
                    trailingSilence: isSeparator ? .sectionBreak : nil))
        }
        return NarrationRenderPlan(
            blocks: NarrationRenderPlanner.attachTrailingSilences(to: planned))
    }

    /// Pack complete sentences up to the word budget. An unusually long sentence
    /// splits at whitespace, preserving every source token and bounding audio RAM.
    static func chunkTexts(_ text: String, maxWords: Int = 200) -> [String] {
        let limit = max(1, maxWords)
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) {
            sentence, _, _, _ in
            if let sentence { sentences.append(sentence) }
        }
        if sentences.isEmpty { sentences = [text] }
        var chunks: [String] = []
        var pending: [String] = []
        for sentence in sentences {
            var words = WordTokenizer.words(in: sentence).map(String.init)[...]
            if pending.count + words.count > limit, !pending.isEmpty {
                chunks.append(pending.joined(separator: " "))
                pending.removeAll(keepingCapacity: true)
            }
            while words.count > limit {
                chunks.append(words.prefix(limit).joined(separator: " "))
                words = words.dropFirst(limit)
            }
            pending.append(contentsOf: words)
        }
        if !pending.isEmpty { chunks.append(pending.joined(separator: " ")) }
        return chunks
    }
}
