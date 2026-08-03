// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import MisakiSwift
    import NaturalLanguage

    /// Final acoustic spelling adjustments applied after Misaki selects IPA and
    /// before Kokoro token IDs are created. Keep these token-scoped so a phoneme
    /// cluster inside an unrelated spelling cannot be rewritten accidentally.
    nonisolated enum KokoroAcousticPronunciationNormalizer {
        static func normalize(_ ipa: String, forWord word: String) -> String {
            let normalizedWord = PronunciationAuditContext.normalizedWord(word)
            guard normalizedWord.hasSuffix("ble") || normalizedWord.hasSuffix("bles") else {
                return ipa
            }
            return ipa.replacing("bᵊl", with: "bəl")
        }
    }

    /// Pure validation boundary between Misaki's mutable token objects and the
    /// exact aggregate phoneme sequence dispatched to Kokoro.
    nonisolated enum PronunciationEvidenceValidator {
        struct Snapshot: Sendable {
            let text: String
            let whitespace: String
            let selectedPhonemes: String
            let lexicalTag: String?
            let rating: Int?
            /// `"left+right"` when the token was voiced from two known lexical
            /// components. Defaults to `nil` because every other resolution path
            /// — lexicon, inflection, whole-token guess — has no components to
            /// report.
            var compoundComponents: String? = nil
        }

        struct Result: Equatable, Sendable {
            let evidence: [PronunciationTokenEvidence]
            let validation: PronunciationEvidenceValidation
        }

        static func validate(
            snapshots: [Snapshot],
            displayText: String,
            finalPhonemes: String
        ) -> Result {
            var reconstructedDisplayText = ""
            var reconstructedTokenPhonemes = ""
            var evidence: [PronunciationTokenEvidence] = []
            evidence.reserveCapacity(snapshots.count)

            for snapshot in snapshots {
                let displayLowerBound = reconstructedDisplayText.count
                reconstructedDisplayText.append(contentsOf: snapshot.text)
                let displayUpperBound = reconstructedDisplayText.count
                let filteredSelectedPhonemes = snapshot.selectedPhonemes.filter {
                    $0 != KokoroPhonemeVocab.oovMarker
                }
                let phonemeLowerBound = reconstructedTokenPhonemes.count
                reconstructedTokenPhonemes.append(contentsOf: filteredSelectedPhonemes)
                let phonemeUpperBound = reconstructedTokenPhonemes.count
                evidence.append(
                    PronunciationTokenEvidence(
                        text: snapshot.text,
                        selectedPhonemes: snapshot.selectedPhonemes,
                        lexicalTag: snapshot.lexicalTag,
                        rating: snapshot.rating,
                        displayCharacterRange: displayLowerBound..<displayUpperBound,
                        phonemeCharacterRange: phonemeLowerBound..<phonemeUpperBound,
                        usedFallback: snapshot.rating == 1,
                        compoundComponents: snapshot.compoundComponents))
                reconstructedDisplayText.append(contentsOf: snapshot.whitespace)
                reconstructedTokenPhonemes.append(
                    contentsOf: snapshot.whitespace.filter {
                        $0 != KokoroPhonemeVocab.oovMarker
                    })
            }

            guard reconstructedDisplayText == displayText else {
                return Result(
                    evidence: [],
                    validation: .mismatch(
                        expectedDisplayText: displayText,
                        reconstructedSpokenSurface: reconstructedDisplayText))
            }

            let filteredFinalPhonemes = finalPhonemes.filter {
                $0 != KokoroPhonemeVocab.oovMarker
            }
            guard reconstructedTokenPhonemes == filteredFinalPhonemes else {
                return Result(
                    evidence: [],
                    validation: .phonemeSequenceMismatch(
                        finalPhonemes: filteredFinalPhonemes,
                        reconstructedTokenPhonemes: reconstructedTokenPhonemes))
            }
            return Result(evidence: evidence, validation: .matched)
        }
    }

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
            let diagnostics: [PronunciationAuditDiagnostic]

            init(
                phonemes: String,
                fallbackHits: [PronunciationFallbackHit],
                tokenEvidence: [PronunciationTokenEvidence],
                pronunciationEvidenceValidation: PronunciationEvidenceValidation,
                diagnostics: [PronunciationAuditDiagnostic] = []
            ) {
                self.phonemes = phonemes
                self.fallbackHits = fallbackHits
                self.tokenEvidence = tokenEvidence
                self.pronunciationEvidenceValidation = pronunciationEvidenceValidation
                self.diagnostics = diagnostics
            }
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
            let diagnostics = Self.currencyNormalizationDiagnostics(
                from: misakiResult.tokens)
            // Copy reference-typed `MToken`s immediately; no mutable Misaki object
            // crosses this wrapper or an isolation boundary.
            let rawSnapshots = misakiResult.tokens.map { token in
                PronunciationEvidenceValidator.Snapshot(
                    text: token.text,
                    whitespace: token.whitespace,
                    selectedPhonemes: token.phonemes ?? "",
                    lexicalTag: token.tag?.rawValue,
                    rating: token.`_`.rating,
                    compoundComponents: token.`_`.compoundComponents)
            }
            let rawTokenResult = PronunciationEvidenceValidator.validate(
                snapshots: rawSnapshots,
                displayText: displayText,
                finalPhonemes: misakiResult.phonemes)
            guard case .matched = rawTokenResult.validation else {
                let rawFallbackHits = misakiResult.fallbackHits.map {
                    PronunciationFallbackHit(word: $0.word, ipa: $0.phonemes)
                }
                return Result(
                    phonemes: misakiResult.phonemes,
                    fallbackHits: Self.orderedFallbackHits(
                        rawFallbackHits,
                        matching: rawTokenResult),
                    tokenEvidence: rawTokenResult.evidence,
                    pronunciationEvidenceValidation: rawTokenResult.validation,
                    diagnostics: diagnostics)
            }

            let snapshots = rawSnapshots.map { snapshot in
                PronunciationEvidenceValidator.Snapshot(
                    text: snapshot.text,
                    whitespace: snapshot.whitespace,
                    selectedPhonemes: KokoroAcousticPronunciationNormalizer.normalize(
                        snapshot.selectedPhonemes,
                        forWord: snapshot.text),
                    lexicalTag: snapshot.lexicalTag,
                    rating: snapshot.rating,
                    compoundComponents: snapshot.compoundComponents)
            }
            let finalPhonemes = snapshots.reduce(into: "") { result, snapshot in
                result.append(contentsOf: snapshot.selectedPhonemes)
                result.append(contentsOf: snapshot.whitespace)
            }
            let tokenResult = PronunciationEvidenceValidator.validate(
                snapshots: snapshots,
                displayText: displayText,
                finalPhonemes: finalPhonemes)
            let rawFallbackHits = misakiResult.fallbackHits.map {
                PronunciationFallbackHit(
                    word: $0.word,
                    ipa: KokoroAcousticPronunciationNormalizer.normalize(
                        $0.phonemes,
                        forWord: $0.word))
            }
            return Result(
                phonemes: finalPhonemes,
                fallbackHits: Self.orderedFallbackHits(
                    rawFallbackHits,
                    matching: tokenResult),
                tokenEvidence: tokenResult.evidence,
                pronunciationEvidenceValidation: tokenResult.validation,
                diagnostics: diagnostics)
        }

        /// Misaki attaches `currencyExpressionSource` only after its semantic
        /// parser accepts a complete supported expression. A supported symbol
        /// immediately followed by a numeric amount is therefore a rejected
        /// candidate when no semantic token accounts for it. Keep the advisory
        /// content-free: callers need the controlled reason and count, never the
        /// private source text or selected phonemes.
        private static func currencyNormalizationDiagnostics(
            from tokens: [MToken]
        ) -> [PronunciationAuditDiagnostic] {
            let source = tokens.reduce(into: "") { result, token in
                result.append(contentsOf: token.text)
                result.append(contentsOf: token.whitespace)
            }
            let characters = Array(source)
            let supportedSymbols: Set<Character> = ["$", "£", "€"]
            var candidateCount = 0

            for index in characters.indices where supportedSymbols.contains(characters[index]) {
                var amountIndex = index + 1
                guard amountIndex < characters.count else { continue }
                if characters[amountIndex] == "-" {
                    amountIndex += 1
                }
                var sawDigit = false
                while amountIndex < characters.count {
                    let character = characters[amountIndex]
                    guard character.isNumber || character == "." || character == "," else {
                        break
                    }
                    sawDigit = sawDigit || character.isNumber
                    amountIndex += 1
                }
                guard sawDigit else { continue }
                candidateCount += 1
            }

            let acceptedCount = tokens.lazy.compactMap {
                $0.`_`.currencyExpressionSource
            }.count
            let rejectedCount = max(0, candidateCount - acceptedCount)
            return (0..<rejectedCount).map { _ in
                PronunciationAuditDiagnostic(
                    reason: .currencyNormalizationRejected,
                    blockID: "",
                    chunkIndex: 0,
                    expectedDisplayText: "",
                    reconstructedSpokenSurface: "",
                    fallbackHits: [])
            }
        }

        /// Misaki's aggregate fallback array is not guaranteed to be in source
        /// order. When exact token evidence is available, associate every hit
        /// with one unmatched fallback token and publish the canonical reading
        /// order needed by frozen retry slices. If the two sources disagree,
        /// preserve Misaki's aggregate data and let downstream slicing fail closed.
        private static func orderedFallbackHits(
            _ fallbackHits: [PronunciationFallbackHit],
            matching tokenResult: PronunciationEvidenceValidator.Result
        ) -> [PronunciationFallbackHit] {
            guard case .matched = tokenResult.validation else { return fallbackHits }

            var unmatched = fallbackHits
            var ordered: [PronunciationFallbackHit] = []
            for evidence in tokenResult.evidence where evidence.usedFallback {
                guard let matchIndex = unmatched.firstIndex(where: {
                    fallbackEvidence(evidence, matches: $0)
                }) else {
                    return fallbackHits
                }
                ordered.append(unmatched.remove(at: matchIndex))
            }
            return unmatched.isEmpty ? ordered : fallbackHits
        }

        private static func fallbackEvidence(
            _ evidence: PronunciationTokenEvidence,
            matches hit: PronunciationFallbackHit
        ) -> Bool {
            let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            return evidence.text.trimmingCharacters(in: trim).lowercased()
                == hit.word.trimmingCharacters(in: trim).lowercased()
                && evidence.selectedPhonemes.filter { $0 != KokoroPhonemeVocab.oovMarker }
                    == hit.ipa.filter { $0 != KokoroPhonemeVocab.oovMarker }
        }

    }
#endif
