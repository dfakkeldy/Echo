// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

@Suite struct KokoroG2PTests {

    @Test func producesNonEmptyPhonemesForEnglish() {
        let p = KokoroG2P().phonemes(for: "Hello world.")
        #expect(!p.isEmpty)
        // Word boundary is preserved (the vocab maps " " → 16).
        #expect(p.contains(" "))
    }

    @Test func phonemizesDeterministically() {
        // Same input → same output across instances (no RNG-dependent path).
        let a = KokoroG2P().phonemes(for: "The quick brown fox.")
        let b = KokoroG2P().phonemes(for: "The quick brown fox.")
        #expect(a == b)
    }

    @Test func phonemeCountMatchesPhonemeStringLength() {
        let g2p = KokoroG2P()
        let phonemes = g2p.phonemes(for: "Hello world.")

        #expect(g2p.phonemeCount(for: "Hello world.") == phonemes.count)
    }

    @Test func resultReportsOOVFallbackHits() {
        let result = KokoroG2P().result(for: "Jacqui said hello.")
        #expect(!result.phonemes.isEmpty)
        #expect(result.fallbackHits.contains { $0.word == "Jacqui" && !$0.ipa.isEmpty })
        #expect(!result.fallbackHits.contains { $0.word.lowercased().contains("hello") })
    }

    @Test func resultCanonicalizesReversedAggregateFallbacksIntoEvidenceOrder() {
        // Misaki currently reports this pair in reverse aggregate order even
        // though its exact token evidence is in authored reading order.
        let result = KokoroG2P().result(for: "Jacqui checked the filesystem.")
        let evidenceOrder = result.tokenEvidence.filter(\.usedFallback).map {
            PronunciationFallbackHit(word: $0.text, ipa: $0.selectedPhonemes)
        }

        #expect(evidenceOrder.map { $0.word.lowercased() } == ["jacqui", "filesystem"])
        #expect(result.fallbackHits == evidenceOrder)
    }

    @Test func resultPreservesFinalTokenEvidenceInDisplayCharacterRanges() throws {
        let displayText = "The result was verified."
        let result = KokoroG2P().result(
            for: displayText,
            displayText: displayText)

        #expect(result.pronunciationEvidenceValidation == .matched)
        let token = try #require(
            result.tokenEvidence.first { $0.text.lowercased() == "verified" })
        #expect(token.selectedPhonemes == "vˈɛɹəfˌId")
        #expect(token.lexicalTag != nil)
        #expect(token.rating != nil)
        #expect(token.displayCharacterRange == 15..<23)
        #expect(!token.usedFallback)

        let lowerBound = displayText.index(
            displayText.startIndex,
            offsetBy: token.displayCharacterRange.lowerBound)
        let upperBound = displayText.index(
            displayText.startIndex,
            offsetBy: token.displayCharacterRange.upperBound)
        #expect(displayText[lowerBound..<upperBound] == "verified")

        let encoded = try JSONEncoder().encode(token)
        #expect(
            try JSONDecoder().decode(PronunciationTokenEvidence.self, from: encoded)
                == token)
    }

    @Test func bleEndingUsesOpenSchwaInFinalPhonemesAndTokenEvidence() throws {
        let text = "possible comfortable reliable."
        let result = KokoroG2P().result(for: text, displayText: text)

        #expect(result.pronunciationEvidenceValidation == .matched)
        #expect(!result.phonemes.contains("bᵊl"))
        let expected: [String: String] = [
            "possible": "pˈɑsəbəl",
            "comfortable": "kˈʌmfəɹTəbəl",
            "reliable": "ɹəlˈIəbəl",
        ]
        for (word, ipa) in expected {
            let evidence = try #require(
                result.tokenEvidence.first { $0.text.lowercased() == word })
            #expect(evidence.selectedPhonemes == ipa)
            #expect(result.phonemes.contains(ipa))
        }
    }

    @Test func bleNormalizerIsScopedToWordEndings() {
        #expect(
            KokoroAcousticPronunciationNormalizer.normalize(
                "pˈɑsəbᵊl",
                forWord: "possible") == "pˈɑsəbəl")
        #expect(
            KokoroAcousticPronunciationNormalizer.normalize(
                "tˈAbᵊlz",
                forWord: "tables") == "tˈAbəlz")
        #expect(
            KokoroAcousticPronunciationNormalizer.normalize(
                "əsˈɛmbᵊld",
                forWord: "assembled") == "əsˈɛmbᵊld")
    }

    @Test func validatedEvidenceUsesExactDisplayRangesAndCanonicalWordSpans() throws {
        struct EvidenceCase {
            let name: String
            let displayText: String
            let g2pInputText: String
            let tokenText: String
            let expectedRange: Range<Int>
            let expectedWordSpan: ClosedRange<Int>
        }

        let cases = [
            EvidenceCase(
                name: "attached punctuation",
                displayText: "verified,",
                g2pInputText: "verified,",
                tokenText: "verified",
                expectedRange: 0..<8,
                expectedWordSpan: 0...0),
            EvidenceCase(
                name: "contraction",
                displayText: "can't verify",
                g2pInputText: "can't verify",
                tokenText: "can't",
                expectedRange: 0..<5,
                expectedWordSpan: 0...0),
            EvidenceCase(
                name: "non-ASCII prefix",
                displayText: "Café verified",
                g2pInputText: "Café verified",
                tokenText: "verified",
                expectedRange: 5..<13,
                expectedWordSpan: 1...1),
            EvidenceCase(
                name: "explicit pronunciation link",
                displayText: "record",
                g2pInputText: "[record](/ɹəkˈɔɹd/)",
                tokenText: "record",
                expectedRange: 0..<6,
                expectedWordSpan: 0...0),
        ]

        let g2p = KokoroG2P()
        for evidenceCase in cases {
            let result = g2p.result(
                for: evidenceCase.g2pInputText,
                displayText: evidenceCase.displayText)
            let evidence = try #require(
                result.tokenEvidence.first {
                    $0.text.localizedCaseInsensitiveCompare(evidenceCase.tokenText)
                        == .orderedSame
                },
                "Missing token evidence for \(evidenceCase.name)")

            #expect(
                result.pronunciationEvidenceValidation == .matched,
                "Validation failed for \(evidenceCase.name)")
            #expect(
                evidence.displayCharacterRange == evidenceCase.expectedRange,
                "Wrong display range for \(evidenceCase.name)")
            #expect(
                PronunciationAuditContext.wordSpan(
                    overlappingDisplayCharacterRange: evidence.displayCharacterRange,
                    in: evidenceCase.displayText) == evidenceCase.expectedWordSpan,
                "Wrong word span for \(evidenceCase.name)")
        }
    }

    @Test func resultRejectsTokenRangesWhenSpokenSurfaceDoesNotMatchDisplayText() {
        let result = KokoroG2P().result(
            for: "verified",
            displayText: "different")

        #expect(
            result.pronunciationEvidenceValidation
                == .mismatch(
                    expectedDisplayText: "different",
                    reconstructedSpokenSurface: "verified"))
        #expect(result.tokenEvidence.isEmpty)
        #expect(!result.phonemes.isEmpty)
    }

    @Test func validatorRejectsTokenEvidenceThatDoesNotMatchFinalAggregatePhonemes() {
        let result = PronunciationEvidenceValidator.validate(
            snapshots: [
                PronunciationEvidenceValidator.Snapshot(
                    text: "startable",
                    whitespace: "",
                    selectedPhonemes: "stˈɑɹɾəbᵊl",
                    lexicalTag: "Noun",
                    rating: 5)
            ],
            displayText: "startable",
            finalPhonemes: "stˈɑɹTəbᵊl")

        #expect(result.evidence.isEmpty)
        #expect(
            result.validation
                == .phonemeSequenceMismatch(
                    finalPhonemes: "stˈɑɹTəbᵊl",
                    reconstructedTokenPhonemes: "stˈɑɹɾəbᵊl"))
    }
}
