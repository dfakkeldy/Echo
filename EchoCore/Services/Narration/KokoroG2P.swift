// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import MisakiSwift
    import NaturalLanguage

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
        struct Result: Equatable, Sendable {
            let phonemes: String
            let fallbackHits: [PronunciationFallbackHit]
            let tokenEvidence: [PronunciationTokenEvidence]
            let pronunciationEvidenceValidation: PronunciationEvidenceValidation
        }

        /// Echo-owned value snapshot of mutable Misaki token state. Whitespace is
        /// retained only long enough to reconstruct and validate the spoken surface.
        private struct TokenSnapshot: Sendable {
            let text: String
            let whitespace: String
            let selectedPhonemes: String
            let lexicalTag: String?
            let rating: Int?
        }

        private let engine: EnglishG2P

        init() {
            // US English. Initialization loads the Misaki lexicons (~12 MB us-only),
            // so construct this on the narration background path, never the playback
            // path.
            self.engine = EnglishG2P(british: false)
        }

        /// IPA phonemes for `text`, spaces preserved between words.
        func phonemes(for text: String) -> String {
            result(for: text).phonemes
        }

        func phonemeCount(for text: String) -> Int {
            phonemes(for: text).count
        }

        /// IPA phonemes plus OOV fallback metadata for pronunciation discovery.
        func result(for text: String) -> Result {
            result(
                for: text,
                displayText: MisakiPronunciationMarkup.displayText(from: text)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// IPA phonemes, aggregate fallback hits, and position-bearing token
        /// evidence from the same final Misaki call. Evidence is emitted only when
        /// token text plus whitespace exactly reconstructs `displayText`.
        func result(for text: String, displayText: String) -> Result {
            let misakiResult = engine.phonemizeWithMetadata(text: text)
            // Copy reference-typed `MToken`s immediately; no mutable Misaki object
            // crosses this wrapper or an isolation boundary.
            let snapshots = misakiResult.tokens.map { token in
                TokenSnapshot(
                    text: token.text,
                    whitespace: token.whitespace,
                    selectedPhonemes: token.phonemes ?? "",
                    lexicalTag: token.tag?.rawValue,
                    rating: token.`_`.rating)
            }
            let tokenResult = validatedEvidence(
                from: snapshots,
                displayText: displayText)
            return Result(
                phonemes: misakiResult.phonemes,
                fallbackHits: misakiResult.fallbackHits.map {
                    PronunciationFallbackHit(word: $0.word, ipa: $0.phonemes)
                },
                tokenEvidence: tokenResult.evidence,
                pronunciationEvidenceValidation: tokenResult.validation)
        }

        private func validatedEvidence(
            from snapshots: [TokenSnapshot],
            displayText: String
        ) -> (
            evidence: [PronunciationTokenEvidence],
            validation: PronunciationEvidenceValidation
        ) {
            var reconstructed = ""
            var evidence: [PronunciationTokenEvidence] = []
            evidence.reserveCapacity(snapshots.count)

            for snapshot in snapshots {
                let lowerBound = reconstructed.count
                reconstructed.append(contentsOf: snapshot.text)
                let upperBound = reconstructed.count
                evidence.append(
                    PronunciationTokenEvidence(
                        text: snapshot.text,
                        selectedPhonemes: snapshot.selectedPhonemes,
                        lexicalTag: snapshot.lexicalTag,
                        rating: snapshot.rating,
                        displayCharacterRange: lowerBound..<upperBound,
                        usedFallback: snapshot.rating == 1))
                reconstructed.append(contentsOf: snapshot.whitespace)
            }

            guard reconstructed == displayText else {
                return (
                    evidence: [],
                    validation: .mismatch(
                        expectedDisplayText: displayText,
                        reconstructedSpokenSurface: reconstructed)
                )
            }
            return (evidence: evidence, validation: .matched)
        }
    }
#endif
