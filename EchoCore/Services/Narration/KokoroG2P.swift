// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import MisakiSwift

    /// Thin wrapper over MisakiSwift's `EnglishG2P`, the proven-quality Misaki
    /// grapheme→phoneme converter (Apache-2.0, no espeak — Phase 0.3 license
    /// audit). Returns an IPA phoneme string that `KokoroPhonemeVocab` maps to
    /// the Kokoro-82M token ids.
    ///
    /// G2P is lexicon-only: MisakiSwift's MLX-backed BART OOV-fallback network was
    /// removed (see MisakiSwift/Package.swift), so there is no MLX dependency — an
    /// out-of-vocabulary word falls back to Misaki's rule-based pronunciation.
    ///
    /// US English only (Echo ships no `gb_*` resources).
    nonisolated struct KokoroG2P {
        private let engine: EnglishG2P

        init() {
            // US English. Initialization loads the Misaki lexicons (~12 MB us-only),
            // so construct this on the narration background path, never the playback
            // path.
            self.engine = EnglishG2P(british: false)
        }

        /// IPA phonemes for `text`, spaces preserved between words.
        func phonemes(for text: String) -> String {
            let (phonemes, _) = engine.phonemize(text: text)
            return phonemes
        }
    }
#endif
