// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite(.serialized) struct PronunciationCandidateAnalyzerTests {
    @Test func overrideRetainsSelectedIPAAndSuppressesLowerAuthorityAlternatives() throws {
        let seed = makeSeed(
            source: .occurrenceOverride,
            selectedIPA: "ɹˈɛkɚd",
            candidateID: "occurrence.record")
        let evidence = try #require(try makeAnalyzer().evidence(
            for: seed,
            fallbackHits: [],
            isWatchWord: false))

        #expect(seed.selectedIPA == "ɹˈɛkɚd")
        #expect(evidence.selectedAuthority == .trusted)
        #expect(evidence.selectedCandidateID == "occurrence.record")
        #expect(evidence.selectionReason == .occurrenceOverride)
        #expect(evidence.overrideSuppressedAutomation)
        #expect(!evidence.alternatives.isEmpty)
        #expect(evidence.alternatives.allSatisfy { $0.validation == .shadow })
    }

    @Test func knownSourceDisagreementProducesValidatedAlternativesWithoutChangingSelection() throws {
        let seed = makeSeed(
            source: .monitoredLexicon,
            selectedIPA: "ɹˈɛkɚd")
        let evidence = try #require(try makeAnalyzer().evidence(
            for: seed,
            fallbackHits: [],
            isWatchWord: false))

        #expect(seed.selectedIPA == "ɹˈɛkɚd")
        #expect(evidence.selectionReason == .sourceDisagreement)
        #expect(evidence.selectedAuthority == .trusted)
        #expect(evidence.alternatives.map(\.ipa) == ["ɹɪkˈɔɹd", "ɹəkˈɔɹd", "ɹˈɛkəɹd"])
        #expect(evidence.alternatives.map(\.source) == [
            "cmudict", "cmudict", "echo-us-gold",
        ])
    }

    @Test func multipleProductionCandidatesRemainAdvisoryOnly() throws {
        let productionURL = try #require(NarrationResources.url(
            forResource: "us_pronunciation_pack",
            withExtension: "json"))
        let analyzer = PronunciationCandidateAnalyzer(
            productionPack: try EnglishPronunciationPack(data: Data(contentsOf: productionURL)),
            auditPack: .empty)
        let seed = makeSeed(
            normalizedWord: "aalen",
            sourceWord: "Aalen",
            source: .monitoredLexicon,
            selectedIPA: "ˈælən")

        let evidence = try #require(analyzer.evidence(
            for: seed,
            fallbackHits: [],
            isWatchWord: false))

        #expect(seed.selectedIPA == "ˈælən")
        #expect(evidence.alternatives.isEmpty)
        #expect(evidence.selectedAuthority == .trusted)
    }

    @Test func ordinaryKnownWordWithoutComparisonSignalsHasNoAdvisoryEvidence() {
        let seed = makeSeed(
            normalizedWord: "ordinary",
            sourceWord: "ordinary",
            source: .monitoredLexicon,
            selectedIPA: "ˈɔɹdɪnˌɛɹi")

        #expect(PronunciationCandidateAnalyzer(
            productionPack: .empty,
            auditPack: .empty
        ).evidence(
            for: seed,
            fallbackHits: [],
            isWatchWord: false) == nil)
    }

    @Test func sentenceInitialOrdinaryKnownWordHasNoAdvisoryEvidence() throws {
        let seed = makeSeed(
            normalizedWord: "ordinary",
            sourceWord: "Ordinary",
            source: .monitoredLexicon,
            selectedIPA: "ˈɔɹdɪnˌɛɹi")

        #expect(PronunciationCandidateAnalyzer(
            productionPack: .empty,
            auditPack: .empty
        ).evidence(
            for: seed,
            fallbackHits: [],
            isWatchWord: false) == nil)
    }

    @Test func scopedComparisonTriggersAreLimitedToNamedSignals() throws {
        let analyzer = PronunciationCandidateAnalyzer(
            productionPack: .empty,
            auditPack: .empty)
        let normal = makeSeed(
            normalizedWord: "ordinary",
            sourceWord: "ordinary",
            source: .monitoredLexicon,
            selectedIPA: "ˈɔɹdɪnˌɛɹi")
        let cases: [(PronunciationDecisionSeed, [PronunciationFallbackHit], Bool)] = [
            (makeSeed(
                normalizedWord: "oov",
                source: .fallback,
                selectedIPA: "oʊv"), [], false),
            (makeSeed(
                normalizedWord: "live",
                source: .contextualHomograph,
                selectedIPA: "lˈIv"), [], false),
            (makeSeed(
                normalizedWord: "nasa",
                sourceWord: "NASA",
                source: .monitoredLexicon,
                selectedIPA: "nˈæsə"), [], false),
            (makeSeed(
                normalizedWord: "empty",
                source: .monitoredLexicon,
                selectedIPA: ""), [], false),
            (makeSeed(
                normalizedWord: "unsupported",
                source: .monitoredLexicon,
                selectedIPA: "\u{0000}"), [], false),
            (normal, [], true),
            (normal, [PronunciationFallbackHit(word: "ordinary", ipa: "ˈɔɹdɪnˌɛɹi")], false),
        ]

        for (seed, fallbackHits, isWatchWord) in cases {
            #expect(analyzer.evidence(
                for: seed,
                fallbackHits: fallbackHits,
                isWatchWord: isWatchWord) != nil)
        }
    }

    private func makeAnalyzer() throws -> PronunciationCandidateAnalyzer {
        let url = try #require(NarrationResources.url(
            forResource: "us_pronunciation_audit_pack",
            withExtension: "json"))
        return PronunciationCandidateAnalyzer(
            productionPack: .empty,
            auditPack: try EnglishPronunciationAuditPack(data: Data(contentsOf: url)))
    }

    private func makeSeed(
        normalizedWord: String = "record",
        sourceWord: String = "record",
        source: PronunciationAuditDecision.Source,
        selectedIPA: String,
        candidateID: String? = nil
    ) -> PronunciationDecisionSeed {
        PronunciationDecisionSeed(
            blockID: "synthetic-block",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: "synthetic context",
            selectedIPA: selectedIPA,
            source: source,
            ruleID: "synthetic.rule",
            rationale: "Synthetic test seed.",
            candidateID: candidateID)
    }
}
