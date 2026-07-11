// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated final class PronunciationPlanner {
    private let g2p: KokoroG2P
    private let vocab: KokoroPhonemeVocab

    init() throws {
        self.g2p = KokoroG2P()
        self.vocab = try KokoroPhonemeVocab()
    }

    func plan(displayText: String, g2pInputText: String) throws -> PlannedSynthesisChunk {
        let result = g2p.result(for: g2pInputText)
        let phonemeIDs = try vocab.validatedIDs(forPhonemes: result.phonemes)
        return PlannedSynthesisChunk(
            displayText: displayText,
            g2pInputText: g2pInputText,
            phonemes: result.phonemes,
            phonemeIDs: phonemeIDs,
            wordCount: WordTokenizer.words(in: displayText).count,
            pronunciationFallbackHits: result.fallbackHits)
    }

    /// Plans text whose pronunciation choices have already been resolved.
    func planResolved(_ resolvedText: String) throws -> PlannedSynthesisChunk {
        try plan(
            displayText: MisakiPronunciationMarkup.displayText(from: resolvedText),
            g2pInputText: resolvedText
        )
    }
}
