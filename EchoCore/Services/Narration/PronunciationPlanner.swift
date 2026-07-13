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
        // Defense-in-depth: drop MisakiSwift's out-of-vocabulary marker before
        // validation so a stray unencodable glyph can never abort the whole chapter
        // render via `validatedIDs`. In today's MisakiSwift the fallback network
        // already maps unphonemizable tokens to a schwa or "" (never `❓`), so this
        // is future-proofing against `unk` leakage rather than a currently-reachable
        // path — the real protection against a bricked render is entry-time IPA
        // validation in `PronunciationOverrideStore`, which keeps unsupported
        // characters out of overrides. `validatedIDs` stays strict for everything
        // else, so a genuine authoring bug (e.g. a bad built-in default) still fails
        // loudly. Dropping the marker matches the historical lenient `ids()` behavior.
        let phonemes = result.phonemes.filter { $0 != KokoroPhonemeVocab.oovMarker }
        let phonemeIDs = try vocab.validatedIDs(forPhonemes: phonemes)
        return PlannedSynthesisChunk(
            displayText: displayText,
            g2pInputText: g2pInputText,
            phonemes: phonemes,
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

    /// Phoneme count for `text`, reusing the planner's already-loaded G2P.
    ///
    /// Chunkers need this to size splits; routing it through the planner keeps
    /// the ~12 MB Misaki lexicon loaded exactly once per render unit instead of
    /// forcing every caller to construct a second `KokoroG2P`.
    func phonemeCount(for text: String) -> Int {
        g2p.phonemeCount(for: text)
    }

    /// Kokoro vocabulary IDs for an already-selected IPA value, excluding the
    /// synthetic boundary tokens required around a complete synthesis request.
    func phonemeIDs(forIPA ipa: String) throws -> [Int32] {
        Array(try vocab.validatedIDs(forPhonemes: ipa).dropFirst().dropLast())
    }
}
