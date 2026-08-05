// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import Testing

@testable import Echo

@Suite(.serialized) struct NarrationPronunciationPreflightTests {
    private struct NeuralCorpusProbe: Decodable {
        let word: String
    }

    private actor EvaluatedWords {
        private var values: [String] = []

        func append(_ word: String) {
            values.append(word)
        }

        func snapshot() -> [String] {
            values
        }
    }

    @Test func flagsAcronymsAndProperNounsNotAlreadyOverridden() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["Xcode talks to NASA and Fakkeldy."],
            overrides: PronunciationOverrides(entries: ["Fakkeldy": "fɑkəldi"]),
            phonemes: { word in word == "Xcode" ? "" : "ok" })

        #expect(candidates.map(\.word).contains("Xcode"))
        #expect(candidates.map(\.word).contains("NASA"))
        #expect(!candidates.map(\.word).contains("Fakkeldy"))
    }

    @Test func collapsesRepeatedCandidates() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["Kubernetes Kubernetes Kubernetes"],
            overrides: PronunciationOverrides(entries: [:]),
            phonemes: { _ in "" })

        #expect(candidates.count == 1)
        #expect(candidates[0].occurrenceCount == 3)
    }

    @Test func flagsFallbackPronunciationsBeforeRender() {
        let candidates = NarrationPronunciationPreflight.scan(
            texts: ["verified verified inclusive"],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciation: { word in
                if word == "verified" {
                    return ("vˈɛɹɪfid", [PronunciationFallbackHit(word: word, ipa: "vˈɛɹɪfid")])
                }
                return ("ok", [])
            })

        #expect(candidates.count == 1)
        #expect(candidates[0].word == "verified")
        #expect(candidates[0].reasons == [.fallbackPronunciation])
        #expect(candidates[0].occurrenceCount == 2)
    }

    @Test func candidatesEncodeAsStableLocalReportJSON() throws {
        let candidates = [
            NarrationPronunciationCandidate(
                word: "Xcode",
                reasons: [
                    .emptyPhonemes,
                    .fallbackPronunciation,
                    .properNoun,
                    .sourceDisagreement,
                    .multipleTrustedPronunciations,
                    .contextualFamily,
                    .unsupportedPhonemes,
                ],
                occurrenceCount: 4)
        ]

        let data = try NarrationPronunciationPreflight.encodeReport(candidates)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""word" : "Xcode""#))
        #expect(json.contains(#""occurrenceCount" : 4"#))
        #expect(json.contains("emptyPhonemes"))
        #expect(json.contains("fallbackPronunciation"))
        #expect(json.contains("properNoun"))
        #expect(json.contains("sourceDisagreement"))
        #expect(json.contains("multipleTrustedPronunciations"))
        #expect(json.contains("contextualFamily"))
        #expect(json.contains("unsupportedPhonemes"))
    }

    @Test func neuralShadowEvaluatesEachNormalizedOOVOnceOffMainAndPreservesSelection()
        async throws
    {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(text: "Xyzqwf xyzqwf verified.")],
            overrides: PronunciationOverrides(entries: [:]))
        let originalChunks = plan.blocks.flatMap(\.synthesisChunks)
        let originalSelections = plan.blocks.flatMap(\.pronunciationDecisions).map {
            [$0.normalizedWord, $0.selectedIPA, $0.candidateID ?? ""]
        }
        let evaluated = EvaluatedWords()

        let enriched = try await NarrationPronunciationPreflight.applyingNeuralShadow(
            to: plan,
            evaluator: { word in
                await evaluated.append(word)
                return .candidate(Self.neuralCandidate())
            })

        #expect(await evaluated.snapshot() == ["xyzqwf"])
        #expect(enriched.blocks.flatMap(\.synthesisChunks) == originalChunks)
        #expect(
            enriched.blocks.flatMap(\.pronunciationDecisions).map {
                [$0.normalizedWord, $0.selectedIPA, $0.candidateID ?? ""]
            } == originalSelections)
        let fallback = try #require(
            enriched.blocks.flatMap(\.pronunciationDecisions).first {
                $0.normalizedWord == "xyzqwf"
            })
        let neural = try #require(
            fallback.advisoryEvidence?.alternatives.first {
                $0.candidateID == Self.neuralCandidate().candidateID
            })
        #expect(neural.authority == .uncertain)
        #expect(neural.validation == .shadow)
        #expect(neural.policyVersion == "mini-bart-g2p-beam5-max20-v1")
        #expect(neural.policyVersion != "neural-oov-complete-selection-v1")
        #expect(fallback.advisoryEvidence?.selectionReason == .shadowCandidate)
        #expect(fallback.advisoryEvidence?.neuralShadowObservation == .candidate)
        #expect(fallback.advisoryEvidence?.isValid(for: fallback) == true)
        #expect(
            enriched.blocks.flatMap(\.pronunciationDecisions).first {
                $0.normalizedWord == "verified"
            }?.advisoryEvidence?.alternatives.contains {
                $0.candidateID == Self.neuralCandidate().candidateID
            } == false)
        #if DEBUG
            #expect(NarrationPronunciationPreflight.debugNeuralBatchRanOnMainThread.withLock { $0 }
                == false)
        #endif
    }

    @Test func neuralFailuresRemainCategoricalAdvisoriesWithoutChangingDeterministicIPA()
        async throws
    {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(text: "Xyzqwf appears.")],
            overrides: PronunciationOverrides(entries: [:]))
        let original = try #require(
            plan.blocks.flatMap(\.pronunciationDecisions).first {
                $0.normalizedWord == "xyzqwf"
            })
        let cases: [(
            NeuralG2PFailure,
            PronunciationAdvisoryEvidence.SelectionReason,
            PronunciationAdvisoryEvidence.NeuralShadowObservation
        )] = [
            (.unavailable, .modelUnavailable, .modelUnavailable),
            (.integrity, .modelIntegrityFailure, .modelIntegrityFailure),
            (.tokenization, .invalidCandidate, .invalidCandidate),
            (.decoding, .invalidCandidate, .invalidCandidate),
            (.emptyOutput, .invalidCandidate, .invalidCandidate),
            (.unsupportedOutput, .invalidCandidate, .invalidCandidate),
            (.inference, .modelInferenceFailure, .modelInferenceFailure),
        ]

        for (failure, expectedReason, expectedObservation) in cases {
            let enriched = try await NarrationPronunciationPreflight.applyingNeuralShadow(
                to: plan,
                evaluator: { _ in .rejected(failure) })
            let decision = try #require(
                enriched.blocks.flatMap(\.pronunciationDecisions).first {
                    $0.normalizedWord == "xyzqwf"
                })
            #expect(decision.selectedIPA == original.selectedIPA)
            #expect(decision.kokoroTokenIDs == original.kokoroTokenIDs)
            #expect(decision.advisoryEvidence?.selectionReason == expectedReason)
            #expect(
                decision.advisoryEvidence?.neuralShadowObservation == expectedObservation)
        }

        enum InjectedFailure: Error { case unavailable }
        let thrown = try await NarrationPronunciationPreflight.applyingNeuralShadow(
            to: plan,
            evaluator: { _ in throw InjectedFailure.unavailable })
        let thrownDecision = try #require(
            thrown.blocks.flatMap(\.pronunciationDecisions).first {
                $0.normalizedWord == "xyzqwf"
            })
        #expect(thrownDecision.advisoryEvidence?.selectionReason == .modelInferenceFailure)
        #expect(
            thrownDecision.advisoryEvidence?.neuralShadowObservation
                == .modelInferenceFailure)

        let malformed = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate(candidateID: "")),
            to: original)
        #expect(malformed.advisoryEvidence?.alternatives == original.advisoryEvidence?.alternatives)
        #expect(malformed.advisoryEvidence?.selectionReason == .invalidCandidate)
        #expect(malformed.advisoryEvidence?.neuralShadowObservation == .invalidCandidate)
        #expect(malformed.advisoryEvidence?.isValid(for: malformed) == true)
    }

    @Test func neuralCancellationAbortsPreflight() async throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(text: "Xyzqwf appears.")],
            overrides: PronunciationOverrides(entries: [:]))

        await #expect(throws: CancellationError.self) {
            _ = try await NarrationPronunciationPreflight.applyingNeuralShadow(
                to: plan,
                evaluator: { _ in .rejected(.cancelled) })
        }
    }

    @Test func neuralShadowPreservesAnInvalidRawG2PEvidenceReceipt() async throws {
        let rawResult = KokoroG2P.Result(
            phonemes: "\u{0000}",
            fallbackHits: [.init(word: "Xyzqwf", ipa: "\u{0000}")],
            tokenEvidence: [.init(
                text: "Xyzqwf",
                selectedPhonemes: "\u{0000}",
                lexicalTag: nil,
                rating: 1,
                displayCharacterRange: 0..<6,
                phonemeCharacterRange: 0..<1,
                usedFallback: true)],
            pronunciationEvidenceValidation: .matched)
        let planner = try PronunciationPlanner(g2pResult: { _, _ in rawResult })
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(text: "Xyzqwf")],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationPlanner: planner)

        let enriched = try await NarrationPronunciationPreflight.applyingNeuralShadow(
            to: plan,
            evaluator: { _ in .candidate(Self.neuralCandidate()) })
        let decision = try #require(enriched.blocks.first?.pronunciationDecisions.first)

        #expect(decision.advisoryEvidence?.alternatives.count == 1)
        #expect(decision.advisoryEvidence?.selectionReason == .deterministicFallback)
        #expect(decision.advisoryEvidence?.neuralShadowObservation == .candidate)
        #expect(decision.isEvidenceOnlyInvalidOutputAdvisory)

        let duplicate = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate()),
            to: decision)
        #expect(duplicate.advisoryEvidence?.alternatives == decision.advisoryEvidence?.alternatives)
        #expect(duplicate.advisoryEvidence?.selectionReason == .deterministicFallback)
        #expect(
            duplicate.advisoryEvidence?.neuralShadowObservation
                == .agreementExistingAlternative)
        #expect(duplicate.isEvidenceOnlyInvalidOutputAdvisory)

        let unavailable = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .rejected(.unavailable),
            to: decision)
        #expect(unavailable.advisoryEvidence?.alternatives == decision.advisoryEvidence?.alternatives)
        #expect(unavailable.advisoryEvidence?.selectionReason == .deterministicFallback)
        #expect(unavailable.advisoryEvidence?.neuralShadowObservation == .modelUnavailable)
        #expect(unavailable.isEvidenceOnlyInvalidOutputAdvisory)
    }

    @Test func neuralSelectedIdentityRequiresMatchingIPAAndRejectsConflictingIPA()
        async throws
    {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(text: "Xyzqwf appears.")],
            overrides: PronunciationOverrides(entries: [:]))
        let original = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "xyzqwf"
            })
        let originalEvidence = try #require(original.advisoryEvidence)
        let ipaAgreement = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate(
                candidateID: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ipa: original.selectedIPA.decomposedStringWithCanonicalMapping)),
            to: original)
        #expect(ipaAgreement.advisoryEvidence?.alternatives == originalEvidence.alternatives)
        #expect(ipaAgreement.advisoryEvidence?.selectionReason == .shadowAgreementSelected)
        #expect(ipaAgreement.advisoryEvidence?.neuralShadowObservation == .agreementSelected)
        #expect(ipaAgreement.advisoryEvidence?.isValid(for: ipaAgreement) == true)

        let selectedCandidateID = "selected.fallback"
        let evidenceWithSelectedIdentity = PronunciationAdvisoryEvidence(
            category: originalEvidence.category,
            selectedAuthority: originalEvidence.selectedAuthority,
            selectedCandidateID: selectedCandidateID,
            alternatives: originalEvidence.alternatives,
            selectionReason: originalEvidence.selectionReason,
            overrideSuppressedAutomation: originalEvidence.overrideSuppressedAutomation,
            policyVersion: originalEvidence.policyVersion)
        let decisionWithSelectedIdentity = Self.replacingAdvisoryEvidence(
            evidenceWithSelectedIdentity,
            in: original,
            candidateID: selectedCandidateID)
        #expect(evidenceWithSelectedIdentity.isValid(for: decisionWithSelectedIdentity))
        let identityAgreement = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate(
                candidateID: selectedCandidateID,
                ipa: original.selectedIPA.decomposedStringWithCanonicalMapping)),
            to: decisionWithSelectedIdentity)
        #expect(
            identityAgreement.advisoryEvidence?.alternatives
                == evidenceWithSelectedIdentity.alternatives)
        #expect(
            identityAgreement.advisoryEvidence?.selectionReason == .shadowAgreementSelected)
        #expect(
            identityAgreement.advisoryEvidence?.neuralShadowObservation
                == .agreementSelected)
        #expect(identityAgreement.advisoryEvidence?.isValid(for: identityAgreement) == true)

        let identityConflict = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate(
                candidateID: selectedCandidateID,
                ipa: "zizkwf")),
            to: decisionWithSelectedIdentity)
        #expect(
            identityConflict.advisoryEvidence?.alternatives
                == evidenceWithSelectedIdentity.alternatives)
        #expect(
            identityConflict.advisoryEvidence?.selectionReason
                == .shadowSelectedCandidateIDConflict)
        #expect(
            identityConflict.advisoryEvidence?.neuralShadowObservation
                == .selectedCandidateIDConflict)
        #expect(identityConflict.advisoryEvidence?.isValid(for: identityConflict) == true)
    }

    @Test func neuralExistingIdentityRequiresMatchingIPAAndRejectsConflictingIPA()
        async throws
    {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(text: "Xyzqwf appears.")],
            overrides: PronunciationOverrides(entries: [:]))
        let original = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "xyzqwf"
            })
        let originalEvidence = try #require(original.advisoryEvidence)
        let existing = PronunciationAdvisoryEvidence.Alternative(
            candidateID: "existing.shadow", ipa: "bæd", source: "fixture",
            authority: .uncertain, validation: .shadow, policyVersion: "fixture-v1")
        let evidenceWithAlternative = PronunciationAdvisoryEvidence(
            category: originalEvidence.category,
            selectedAuthority: originalEvidence.selectedAuthority,
            selectedCandidateID: originalEvidence.selectedCandidateID,
            alternatives: [existing],
            selectionReason: originalEvidence.selectionReason,
            overrideSuppressedAutomation: originalEvidence.overrideSuppressedAutomation,
            policyVersion: originalEvidence.policyVersion)
        let decisionWithAlternative = Self.replacingAdvisoryEvidence(
            evidenceWithAlternative,
            in: original)
        #expect(evidenceWithAlternative.isValid(for: decisionWithAlternative))
        let identityAgreement = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate(
                candidateID: existing.candidateID,
                ipa: existing.ipa.decomposedStringWithCanonicalMapping)),
            to: decisionWithAlternative)
        #expect(identityAgreement.advisoryEvidence?.alternatives == [existing])
        #expect(
            identityAgreement.advisoryEvidence?.selectionReason
                == .shadowAgreementExistingAlternative)
        #expect(
            identityAgreement.advisoryEvidence?.neuralShadowObservation
                == .agreementExistingAlternative)
        #expect(identityAgreement.advisoryEvidence?.isValid(for: identityAgreement) == true)

        let identityConflict = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate(
                candidateID: existing.candidateID,
                ipa: "zizkwf")),
            to: decisionWithAlternative)
        #expect(identityConflict.advisoryEvidence?.alternatives == [existing])
        #expect(
            identityConflict.advisoryEvidence?.selectionReason
                == .shadowExistingAlternativeCandidateIDConflict)
        #expect(
            identityConflict.advisoryEvidence?.neuralShadowObservation
                == .existingAlternativeCandidateIDConflict)
        #expect(identityConflict.advisoryEvidence?.isValid(for: identityConflict) == true)

        let ipaAgreement = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(Self.neuralCandidate(
                candidateID: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                ipa: existing.ipa.decomposedStringWithCanonicalMapping)),
            to: decisionWithAlternative)
        #expect(ipaAgreement.advisoryEvidence?.alternatives == [existing])
        #expect(
            ipaAgreement.advisoryEvidence?.selectionReason
                == .shadowAgreementExistingAlternative)
        #expect(
            ipaAgreement.advisoryEvidence?.neuralShadowObservation
                == .agreementExistingAlternative)
        #expect(ipaAgreement.advisoryEvidence?.isValid(for: ipaAgreement) == true)
    }

    @Test func bundledNeuralModelIsStableAcrossTheFullSyntheticCorpus() async throws {
        let corpusURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Pronunciation/neural_oov_candidates_v1.jsonl")
        let lines = try String(contentsOf: corpusURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(lines.count == 10)

        let decoder = JSONDecoder()
        for line in lines {
            let probe = try decoder.decode(NeuralCorpusProbe.self, from: Data(line.utf8))
            let first = try await MiniBARTG2PEngine.shared.evaluate(word: probe.word)
            let repeated = try await MiniBARTG2PEngine.shared.evaluate(word: probe.word)
            #expect(first == repeated)
            guard case .candidate(let candidate) = first else {
                Issue.record("bundled neural corpus probe did not produce a candidate")
                continue
            }
            #expect(candidate.modelRevision == MiniBARTG2PEngine.modelRevision)
            #expect(candidate.conversionPolicyVersion == ARPAbetToKokoroIPA.policyVersion)
            #expect(
                candidate.validationPolicyVersion
                    == MiniBARTG2PEngine.validationPolicyVersion)
            #expect(candidate.selectionPolicyVersion == MiniBARTG2PEngine.selectionPolicyVersion)
            #expect(candidate.selectionPolicyVersion != "neural-oov-complete-selection-v1")
        }
    }

    nonisolated private static func neuralCandidate(
        candidateID: String =
            "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        ipa: String = "zizkwf"
    ) -> NeuralG2PCandidate {
        NeuralG2PCandidate(
            candidateID: candidateID,
            ipa: ipa,
            modelRevision: "f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06",
            conversionPolicyVersion: "mini-bart-arpabet-to-kokoro-v1",
            validationPolicyVersion: "kokoro-vocab-validation-v1",
            selectionPolicyVersion: "mini-bart-g2p-beam5-max20-v1")
    }

    nonisolated private static func replacingAdvisoryEvidence(
        _ advisoryEvidence: PronunciationAdvisoryEvidence,
        in decision: PronunciationAuditDecision,
        candidateID: String? = nil
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: decision.blockID,
            wordStart: decision.wordStart,
            wordEnd: decision.wordEnd,
            normalizedWord: decision.normalizedWord,
            sourceWord: decision.sourceWord,
            sourceContext: decision.sourceContext,
            selectedIPA: decision.selectedIPA,
            kokoroTokenIDs: decision.kokoroTokenIDs,
            source: decision.source,
            ruleID: decision.ruleID,
            rationale: decision.rationale,
            candidateID: candidateID ?? decision.candidateID,
            candidatePackVersion: decision.candidatePackVersion,
            derivationBase: decision.derivationBase,
            derivationRuleID: decision.derivationRuleID,
            contextualEvidence: decision.contextualEvidence,
            advisoryEvidence: advisoryEvidence,
            chapterIndex: decision.chapterIndex,
            chapterRelativeAudioRange: decision.chapterRelativeAudioRange,
            bookRelativeAudioRange: decision.bookRelativeAudioRange,
            timingPrecision: decision.timingPrecision)
    }

    private func block(text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "neural-shadow", audiobookID: "book", spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue, text: text,
            htmlContent: nil, cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }
}
