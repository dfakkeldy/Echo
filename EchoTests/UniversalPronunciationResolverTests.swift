// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct UniversalPronunciationResolverTests {
    private let semanticPackVersion =
        "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    private let vocabularyVersion =
        "sha256:1111111111111111111111111111111111111111111111111111111111111111"

    private func pack(
        automaticEntries: [String: (candidateID: String, ipa: String)] = [:],
        ambiguousWords: Set<String> = [],
        packVersion: String? = nil,
        kokoroVocabularyVersion: String? = nil,
        generationTimestamp: String = "2026-07-29T00:00:00Z"
    ) -> EnglishPronunciationPack {
        EnglishPronunciationPack.emptyForTesting(
            packVersion: packVersion ?? semanticPackVersion,
            kokoroVocabularyVersion: kokoroVocabularyVersion ?? vocabularyVersion,
            generationTimestamp: generationTimestamp,
            automaticEntries: automaticEntries,
            ambiguousWords: ambiguousWords)
    }

    @Test func exactSupplementalCandidateCreatesAuditableLink() throws {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "A foobar appeared.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "A [foobar](/fˈubɑɹ/) appeared.")
        let seed = try #require(result.decisionSeeds.first)
        #expect(result.decisionSeeds.count == 1)
        #expect(seed.source == .supplementalLexicon)
        #expect(seed.candidateID == "cmudict.foobar.fixture")
        #expect(seed.candidatePackVersion == supplementalPack.packVersion)
        #expect(seed.derivationBase == nil)
        #expect(seed.derivationRuleID == nil)
    }

    @Test func exactRewritePreservesCasePunctuationAndExistingLinks() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "Foobar, [foobar](/custom/) and foobar!",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(
            result.text
                == "[Foobar](/fˈubɑɹ/), [foobar](/custom/) and [foobar](/fˈubɑɹ/)!")
        #expect(result.decisionSeeds.map(\.sourceWord) == ["Foobar", "foobar"])
        #expect(result.decisionSeeds.map(\.wordStart) == [0, 3])
    }

    @Test func contextualFamiliesAmbiguousCandidatesAndProperNamesAbstain() {
        let supplementalPack = pack(
            automaticEntries: [
                "content": ("cmudict.content.fixture", "kˈɑntɛnt"),
                "live": ("cmudict.live.fixture", "lˈɪv"),
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ"),
            ],
            ambiguousWords: ["ambiguous"])

        let result = UniversalPronunciationResolver.rewrite(
            to: "The content is live. Meet Foobar and FOOBAR. An ambiguous case.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "The content is live. Meet Foobar and FOOBAR. An ambiguous case.")
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func apostrophePossessiveAbstains() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "The foobar's result.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "The foobar's result.")
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func openingQuoteStillCountsAsSentenceStartForCapitalizationRisk() {
        let supplementalPack = pack(automaticEntries: [
            "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
        ])

        let result = UniversalPronunciationResolver.rewrite(
            to: "“Foobar begins.” Meet “Foobar again.”",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { _ in nil })

        #expect(result.text == "“[Foobar](/fˈubɑɹ/) begins.” Meet “Foobar again.”")
        #expect(result.decisionSeeds.map(\.wordStart) == [0])
    }

    @Test func morphologySupportsExactSilentEAndIbleBases() {
        let known: [String: String] = [
            "start": "stˈɑɹt",
            "reuse": "ɹiːjˈuːz",
            "digest": "daIdʒˈɛst",
        ]
        let result = UniversalPronunciationResolver.rewrite(
            to: "Startable, reusable, digestible.",
            blockID: "b1",
            pack: pack(),
            basePronunciation: { known[$0] })

        #expect(
            result.text
                == "[Startable](/stˈɑɹtəbəl/), [reusable](/ɹiːjˈuːzəbəl/), [digestible](/daIdʒˈɛstəbəl/).")
        #expect(
            result.decisionSeeds.map(\.derivationRuleID)
                == [
                    "morphology.able.exact-base.v1",
                    "morphology.able.silent-e.v1",
                    "morphology.ible.exact-base.v1",
                ])
        #expect(result.decisionSeeds.map(\.derivationBase) == ["start", "reuse", "digest"])
        #expect(result.decisionSeeds.allSatisfy { $0.source == .derivedMorphology })
        #expect(result.decisionSeeds.allSatisfy { $0.candidateID?.isEmpty == false })
        #expect(result.decisionSeeds.allSatisfy { $0.candidatePackVersion?.isEmpty == false })
    }

    @Test func morphologyRequiresExactlyOneValidatedBase() {
        let result = UniversalPronunciationResolver.rewrite(
            to: "The reusable widget.",
            blockID: "b1",
            pack: pack(),
            basePronunciation: { word in
                ["reus": "ɹˈus", "reuse": "ɹiːjˈuːz"][word]
            })

        #expect(result.text == "The reusable widget.")
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func morphologyRejectsNoBaseExceptionsWholeWordsContextAndProperNames() {
        let supplementalPack = pack(automaticEntries: [
            "available": ("cmudict.available.fixture", "əvˈeIləbəl")
        ])
        let known: [String: String] = [
            "comfort": "kˈʌmfɚt",
            "respons": "ɹɪspˈɑns",
            "read": "ɹˈid",
            "start": "stˈɑɹt",
            "available": "əvˈeIləbəl",
        ]

        let result = UniversalPronunciationResolver.rewrite(
            to: "Comfortable responsible readable unavailable available Meet Startable.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { known[$0] })

        #expect(
            result.text
                == "Comfortable responsible readable unavailable [available](/əvˈeIləbəl/) Meet Startable.")
        #expect(result.decisionSeeds.map(\.normalizedWord) == ["available"])
        #expect(result.decisionSeeds.first?.source == .supplementalLexicon)
    }

    @Test func knownWholeWordOrAnySupplementalCandidateBlocksMorphology() {
        let supplementalPack = pack(ambiguousWords: ["testable"])

        let knownWholeWord = UniversalPronunciationResolver.rewrite(
            to: "A startable testable result.",
            blockID: "b1",
            pack: supplementalPack,
            basePronunciation: { word in
                [
                    "startable": "stˈɑɹtəbəl",
                    "start": "stˈɑɹt",
                    "test": "tˈɛst",
                ][word]
            })

        #expect(knownWholeWord.text == "A startable testable result.")
        #expect(knownWholeWord.decisionSeeds.isEmpty)
    }

    @Test func morphologyIdentityAndCandidateIDMatchFixedVectors() {
        let fixturePack = pack()
        let policyVersion =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: fixturePack)
        let candidateID = UniversalPronunciationResolver.derivedCandidateID(
            normalizedWord: "startable",
            derivationBase: "start",
            derivationRuleID: "morphology.able.exact-base.v1",
            baseIPA: "stˈɑɹt",
            derivedIPA: "stˈɑɹtəbəl",
            candidatePackVersion: policyVersion)

        #expect(
            policyVersion
                == "morphology-v1:sha256:41089299eab04d8047f35f67e52c88e5275797f48a5c45db2497157a3d33169b")
        #expect(candidateID == "morphology.startable.1ed5c734016f")
        #expect(
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: fixturePack)
                == policyVersion)
        #expect(
            UniversalPronunciationResolver.derivedCandidateID(
                normalizedWord: "startable",
                derivationBase: "start",
                derivationRuleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: policyVersion)
                == candidateID)
    }

    @Test func everyMorphologySemanticInputChangesApplicableIdentity() {
        let fixturePack = pack()
        let baseline =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: fixturePack)
        let changedRule = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: fixturePack,
            ruleIDs: [
                "morphology.able.exact-base.v2",
                "morphology.able.silent-e.v1",
                "morphology.ible.exact-base.v1",
            ])
        let changedException = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: fixturePack,
            exceptionWords: UniversalPronunciationResolver.exceptionWords.union(["changeable"]))
        let changedBasePolicy = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: fixturePack,
            baseEvidencePolicyVersion: "kokoro-nonfallback-rating4-v2")
        let changedPack = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: pack(packVersion: "sha256:" + String(repeating: "2", count: 64)))
        let changedVocabulary = UniversalPronunciationResolver.morphologyCandidatePackVersion(
            for: pack(kokoroVocabularyVersion: "sha256:" + String(repeating: "3", count: 64)))

        #expect(Set([baseline, changedRule, changedException, changedBasePolicy, changedPack,
                     changedVocabulary]).count == 6)

        let candidateInputs = [
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("testable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("startable", "test", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("startable", "start", "morphology.able.silent-e.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             baseline),
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹd", "stˈɑɹtəbəl",
             baseline),
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtIbəl",
             baseline),
            ("startable", "start", "morphology.able.exact-base.v1", "stˈɑɹt", "stˈɑɹtəbəl",
             changedPack),
        ]
        let candidateIDs = candidateInputs.map {
            UniversalPronunciationResolver.derivedCandidateID(
                normalizedWord: $0.0,
                derivationBase: $0.1,
                derivationRuleID: $0.2,
                baseIPA: $0.3,
                derivedIPA: $0.4,
                candidatePackVersion: $0.5)
        }
        #expect(Set(candidateIDs).count == candidateIDs.count)
    }

    @Test func invalidCandidateIdentityInputsFailClosed() {
        #expect(
            UniversalPronunciationResolver.derivedCandidateID(
                normalizedWord: "Startable",
                derivationBase: "start",
                derivationRuleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: "morphology-v1:sha256:" + String(repeating: "0", count: 64))
                .isEmpty)
    }
}
