// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct PlannedSynthesisChunk: Equatable, Sendable {
    let displayText: String
    let g2pInputText: String
    let phonemes: String
    let phonemeIDs: [Int32]
    let wordCount: Int
    let pronunciationFallbackHits: [PronunciationFallbackHit]
    let pronunciationTokenEvidence: [PronunciationTokenEvidence]
    let pronunciationEvidenceValidation: PronunciationEvidenceValidation

    init(
        displayText: String,
        g2pInputText: String,
        phonemes: String,
        phonemeIDs: [Int32],
        wordCount: Int,
        pronunciationFallbackHits: [PronunciationFallbackHit],
        pronunciationTokenEvidence: [PronunciationTokenEvidence] = [],
        pronunciationEvidenceValidation: PronunciationEvidenceValidation
    ) {
        self.displayText = displayText
        self.g2pInputText = g2pInputText
        self.phonemes = phonemes
        self.phonemeIDs = phonemeIDs
        self.wordCount = wordCount
        self.pronunciationFallbackHits = pronunciationFallbackHits
        self.pronunciationTokenEvidence = pronunciationTokenEvidence
        self.pronunciationEvidenceValidation = pronunciationEvidenceValidation
    }

    /// Splits a rejected synthesis plan without running G2P again. Every child
    /// is a contiguous slice of the exact display, resolved markup, phoneme,
    /// token-ID, fallback, and token-evidence state accepted for the parent.
    /// Returning an empty array is fail-closed: callers keep the parent rather
    /// than synthesize provenance that cannot be proven to be an exact slice.
    func frozenRetrySlices(maxPhonemes: Int) -> [PlannedSynthesisChunk] {
        guard maxPhonemes > 0,
            case .matched = pronunciationEvidenceValidation,
            phonemeIDs.count == phonemes.count + 2,
            !pronunciationTokenEvidence.isEmpty,
            let units = frozenResolvedUnits(),
            units.count > 1,
            let unitPhonemeBoundaries = frozenUnitPhonemeBoundaries(for: units)
        else {
            return []
        }

        var unitGroups: [Range<Int>] = []
        var groupStart = 0
        for unitIndex in units.indices {
            let candidateCount =
                unitPhonemeBoundaries[unitIndex + 1]
                - unitPhonemeBoundaries[groupStart]
            if unitIndex > groupStart, candidateCount > maxPhonemes {
                unitGroups.append(groupStart..<unitIndex)
                groupStart = unitIndex
            }
        }
        unitGroups.append(groupStart..<units.count)
        guard unitGroups.count > 1 else { return [] }

        let fallbackEvidence = pronunciationTokenEvidence.enumerated().filter {
            $0.element.usedFallback
        }
        guard fallbackEvidence.count == pronunciationFallbackHits.count else { return [] }

        var unmatchedFallbackHits = pronunciationFallbackHits
        var fallbackHitsByGroup = Array(repeating: [PronunciationFallbackHit](), count: unitGroups.count)
        for indexedEvidence in fallbackEvidence {
            guard let hitIndex = unmatchedFallbackHits.firstIndex(where: {
                Self.fallbackEvidence(indexedEvidence.element, matches: $0)
            }) else {
                return []
            }
            let hit = unmatchedFallbackHits.remove(at: hitIndex)
            guard
                let groupIndex = unitGroups.firstIndex(where: { group in
                    let displayLowerBound = units[group.lowerBound].displayRange.lowerBound
                    let displayUpperBound = units[group.upperBound - 1].displayRange.upperBound
                    let displayRange = displayLowerBound..<displayUpperBound
                    return displayRange.contains(indexedEvidence.element.displayCharacterRange.lowerBound)
                })
            else {
                return []
            }
            fallbackHitsByGroup[groupIndex].append(hit)
        }
        guard unmatchedFallbackHits.isEmpty else { return [] }

        let parentInteriorIDs = Array(phonemeIDs.dropFirst().dropLast())
        var slices: [PlannedSynthesisChunk] = []
        slices.reserveCapacity(unitGroups.count)
        for (groupIndex, group) in unitGroups.enumerated() {
            let firstUnit = units[group.lowerBound]
            let lastUnit = units[group.upperBound - 1]
            let displayRange = firstUnit.displayRange.lowerBound..<lastUnit.displayRange.upperBound
            let phonemeLowerBound = unitPhonemeBoundaries[group.lowerBound]
            let phonemeUpperBound = unitPhonemeBoundaries[group.upperBound]
            let phonemeRange = phonemeLowerBound..<phonemeUpperBound
            let resolvedRange = firstUnit.resolvedRange.lowerBound..<lastUnit.resolvedRange.upperBound

            let childDisplay = Self.substring(displayText, characterRange: displayRange)
            let childPhonemes = Self.substring(phonemes, characterRange: phonemeRange)
            let childEvidence: [PronunciationTokenEvidence] =
                pronunciationTokenEvidence.compactMap { evidence -> PronunciationTokenEvidence? in
                guard Self.fullyContains(displayRange, evidence.displayCharacterRange),
                    let parentPhonemeRange = evidence.phonemeCharacterRange,
                    Self.fullyContains(phonemeRange, parentPhonemeRange)
                else {
                    return nil
                }
                let childDisplayLowerBound =
                    evidence.displayCharacterRange.lowerBound - displayRange.lowerBound
                let childDisplayUpperBound =
                    evidence.displayCharacterRange.upperBound - displayRange.lowerBound
                let childDisplayRange = childDisplayLowerBound..<childDisplayUpperBound
                let childPhonemeLowerBound =
                    parentPhonemeRange.lowerBound - phonemeRange.lowerBound
                let childPhonemeUpperBound =
                    parentPhonemeRange.upperBound - phonemeRange.lowerBound
                let childPhonemeRange = childPhonemeLowerBound..<childPhonemeUpperBound
                return PronunciationTokenEvidence(
                    text: evidence.text,
                    selectedPhonemes: evidence.selectedPhonemes,
                    lexicalTag: evidence.lexicalTag,
                    rating: evidence.rating,
                    displayCharacterRange: childDisplayRange,
                    phonemeCharacterRange: childPhonemeRange,
                    usedFallback: evidence.usedFallback)
            }
            let expectedEvidenceCount = pronunciationTokenEvidence.filter {
                Self.fullyContains(displayRange, $0.displayCharacterRange)
            }.count
            guard childEvidence.count == expectedEvidenceCount else { return [] }

            slices.append(
                PlannedSynthesisChunk(
                    displayText: childDisplay,
                    g2pInputText: String(g2pInputText[resolvedRange]),
                    phonemes: childPhonemes,
                    phonemeIDs: [KokoroPhonemeVocab.boundaryTokenId]
                        + Array(parentInteriorIDs[phonemeRange])
                        + [KokoroPhonemeVocab.boundaryTokenId],
                    wordCount: WordTokenizer.words(in: childDisplay).count,
                    pronunciationFallbackHits: fallbackHitsByGroup[groupIndex],
                    pronunciationTokenEvidence: childEvidence,
                    pronunciationEvidenceValidation: .matched))
        }

        guard slices.map(\.phonemes).joined() == phonemes,
            slices.flatMap({ $0.phonemeIDs.dropFirst().dropLast() }) == parentInteriorIDs,
            slices.reduce(0, { $0 + $1.wordCount }) == wordCount,
            slices.flatMap(\.pronunciationFallbackHits) == pronunciationFallbackHits,
            slices.flatMap(\.pronunciationTokenEvidence).count
                == pronunciationTokenEvidence.count,
            slices.flatMap({ WordTokenizer.words(in: $0.displayText).map(String.init) })
                == WordTokenizer.words(in: displayText).map(String.init)
        else {
            return []
        }
        return slices
    }

    private struct FrozenResolvedUnit {
        let resolvedRange: Range<String.Index>
        let displayRange: Range<Int>
    }

    private func frozenResolvedUnits() -> [FrozenResolvedUnit]? {
        var units: [FrozenResolvedUnit] = []
        var index = g2pInputText.startIndex
        var displayOffset = 0

        while index < g2pInputText.endIndex {
            while index < g2pInputText.endIndex, g2pInputText[index].isWhitespace {
                displayOffset += 1
                index = g2pInputText.index(after: index)
            }
            guard index < g2pInputText.endIndex else { break }

            let resolvedStart = index
            let displayStart = displayOffset
            while index < g2pInputText.endIndex, !g2pInputText[index].isWhitespace {
                if let link = MisakiPronunciationMarkup.link(in: g2pInputText, startingAt: index) {
                    displayOffset += link.displayText.count
                    index = link.range.upperBound
                } else {
                    displayOffset += 1
                    index = g2pInputText.index(after: index)
                }
            }
            units.append(
                FrozenResolvedUnit(
                    resolvedRange: resolvedStart..<index,
                    displayRange: displayStart..<displayOffset))
        }

        guard displayOffset == displayText.count else { return nil }
        return units
    }

    private func frozenUnitPhonemeBoundaries(
        for units: [FrozenResolvedUnit]
    ) -> [Int]? {
        var previousDisplayUpperBound = 0
        var previousPhonemeUpperBound = 0
        for evidence in pronunciationTokenEvidence {
            let selectedPhonemes = evidence.selectedPhonemes.filter {
                $0 != KokoroPhonemeVocab.oovMarker
            }
            guard evidence.displayCharacterRange.lowerBound >= previousDisplayUpperBound,
                evidence.displayCharacterRange.upperBound <= displayText.count,
                Self.substring(displayText, characterRange: evidence.displayCharacterRange)
                    == evidence.text,
                let phonemeRange = evidence.phonemeCharacterRange,
                phonemeRange.lowerBound >= previousPhonemeUpperBound,
                phonemeRange.upperBound <= phonemes.count,
                Self.substring(phonemes, characterRange: phonemeRange)
                    == selectedPhonemes
            else {
                return nil
            }
            previousDisplayUpperBound = evidence.displayCharacterRange.upperBound
            previousPhonemeUpperBound = phonemeRange.upperBound
        }

        var boundaries = [0]
        boundaries.reserveCapacity(units.count + 1)
        for unit in units.dropFirst() {
            guard let evidence = pronunciationTokenEvidence.first(where: {
                $0.displayCharacterRange.lowerBound >= unit.displayRange.lowerBound
            }), let phonemeRange = evidence.phonemeCharacterRange
            else {
                return nil
            }
            boundaries.append(phonemeRange.lowerBound)
        }
        boundaries.append(phonemes.count)
        guard zip(boundaries, boundaries.dropFirst()).allSatisfy({ pair in
            pair.0 <= pair.1
        }) else {
            return nil
        }
        return boundaries
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

    private static func substring(_ source: String, characterRange: Range<Int>) -> String {
        let lower = source.index(source.startIndex, offsetBy: characterRange.lowerBound)
        let upper = source.index(source.startIndex, offsetBy: characterRange.upperBound)
        return String(source[lower..<upper])
    }

    private static func fullyContains(_ outer: Range<Int>, _ inner: Range<Int>) -> Bool {
        outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound
    }
}
