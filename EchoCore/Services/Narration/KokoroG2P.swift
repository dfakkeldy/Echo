// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import MisakiSwift

    /// Thin wrapper over MisakiSwift's `EnglishG2P`, the proven-quality Misaki
    /// grapheme→phoneme converter (Apache-2.0, no espeak — Phase 0.3 license
    /// audit). Returns an IPA phoneme string that `KokoroPhonemeVocab` maps to
    /// the Kokoro-82M token ids.
    ///
    /// v1 accepts MisakiSwift's MLX dependency (the BART OOV fallback runs on
    /// MLX); there is no MLX-free path without a fork. The metallib bundles
    /// correctly inside a real app target (the Phase 0 bare-CLI quirk does not
    /// apply here). Fast-follow: a lexicon-only G2P to drop MLX — deferred.
    ///
    /// US English only (Echo ships no `gb_*` resources).
    struct KokoroG2P {
        private let engine: EnglishG2P

        init() {
            // US English. Initialization loads the BART OOV model + lexicons
            // (~12 MB us-only), so construct this on the narration background
            // path, never the playback path.
            self.engine = EnglishG2P(british: false)
        }

        /// IPA phonemes for `text`, spaces preserved between words.
        func phonemes(for text: String) -> String {
            let (phonemes, _) = engine.phonemize(text: text)
            return phonemes
        }
    }
#endif
