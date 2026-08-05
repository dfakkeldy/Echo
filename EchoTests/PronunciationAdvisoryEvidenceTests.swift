// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationAdvisoryEvidenceTests {
    private enum LegacySelectionReason: String, Decodable {
        case occurrenceOverride
        case bookOverride
        case globalOverride
        case qualifiedDeterministicContext
        case trustedLexicon
        case qualifiedNeuralOOV
        case deterministicFallback
        case sourceDisagreement
        case shadowCandidate
        case shadowAgreementSelected
        case shadowAgreementExistingAlternative
        case invalidCandidate
        case modelUnavailable
        case modelIntegrityFailure
        case modelInferenceFailure
        case contextShadow
        case contextUnavailable
        case acousticRetryRejected
    }

    private struct LegacyAdvisoryEvidence: Decodable {
        let category: PronunciationAdvisoryEvidence.Category
        let selectedAuthority: PronunciationAdvisoryEvidence.Authority
        let selectedCandidateID: String?
        let alternatives: [PronunciationAdvisoryEvidence.Alternative]
        let selectionReason: LegacySelectionReason
        let overrideSuppressedAutomation: Bool
        let policyVersion: String
    }

    private func alternative(
        candidateID: String,
        ipa: String,
        source: String = "fixture",
        authority: PronunciationAdvisoryEvidence.Authority = .qualified,
        validation: PronunciationAdvisoryEvidence.Validation = .shadow,
        policyVersion: String = "policy-v1"
    ) -> PronunciationAdvisoryEvidence.Alternative {
        PronunciationAdvisoryEvidence.Alternative(
            candidateID: candidateID,
            ipa: ipa,
            source: source,
            authority: authority,
            validation: validation,
            policyVersion: policyVersion)
    }

    private func neuralAlternative(
        candidateID: String =
            "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        ipa: String = "zizkwf"
    ) -> PronunciationAdvisoryEvidence.Alternative {
        alternative(
            candidateID: candidateID,
            ipa: ipa,
            source:
                "mini-bart-g2p@f277d1e0597e7d33fa1d6d27d764bc4d7acb06"
                + "|mini-bart-arpabet-to-kokoro-v1|kokoro-vocab-validation-v1",
            authority: .uncertain,
            validation: .shadow,
            policyVersion: "mini-bart-g2p-beam5-max20-v1")
    }

    private func evidence(
        selectedCandidateID: String? = nil,
        alternatives: [PronunciationAdvisoryEvidence.Alternative] = [],
        selectionReason: PronunciationAdvisoryEvidence.SelectionReason,
        observation: PronunciationAdvisoryEvidence.NeuralShadowObservation?,
        category: PronunciationAdvisoryEvidence.Category = .lexical,
        selectedAuthority: PronunciationAdvisoryEvidence.Authority = .uncertain,
        overrideSuppressedAutomation: Bool = false
    ) -> PronunciationAdvisoryEvidence {
        PronunciationAdvisoryEvidence(
            category: category,
            selectedAuthority: selectedAuthority,
            selectedCandidateID: selectedCandidateID,
            alternatives: alternatives,
            selectionReason: selectionReason,
            overrideSuppressedAutomation: overrideSuppressedAutomation,
            policyVersion: "policy-v1",
            neuralShadowObservation: observation)
    }

    @Test func roundTripsEveryClosedVocabularyAcrossEvidenceCategories() throws {
        let evidences = [
            PronunciationAdvisoryEvidence(
                category: .lexical,
                selectedAuthority: .trusted,
                selectedCandidateID: "lexical.primary",
                alternatives: [
                    alternative(
                        candidateID: "lexical.shadow",
                        ipa: "lɛksˈɪkəl"),
                ],
                selectionReason: .trustedLexicon,
                overrideSuppressedAutomation: false,
                policyVersion: "policy-v1"),
            PronunciationAdvisoryEvidence(
                category: .contextual,
                selectedAuthority: .qualified,
                selectedCandidateID: "contextual.primary",
                alternatives: [
                    alternative(
                        candidateID: "contextual.shadow",
                        ipa: "kˈɑntɛkstʃuəl",
                        authority: .qualified,
                        validation: .shadow),
                ],
                selectionReason: .qualifiedDeterministicContext,
                overrideSuppressedAutomation: true,
                policyVersion: "policy-v2"),
            PronunciationAdvisoryEvidence(
                category: .acoustic,
                selectedAuthority: .uncertain,
                selectedCandidateID: nil,
                alternatives: [
                    alternative(
                        candidateID: "acoustic.retry",
                        ipa: "əkˈuːstɪk",
                        authority: .uncertain,
                        validation: .rejected),
                ],
                selectionReason: .acousticRetryRejected,
                overrideSuppressedAutomation: false,
                policyVersion: "policy-v3"),
        ]

        for evidence in evidences {
            let decoded = try JSONDecoder().decode(
                PronunciationAdvisoryEvidence.self,
                from: JSONEncoder().encode(evidence))
            #expect(decoded == evidence)
        }

        for reason in [
            PronunciationAdvisoryEvidence.SelectionReason.shadowAgreementSelected,
            .shadowAgreementExistingAlternative,
        ] {
            let encoded = try JSONEncoder().encode(reason)
            #expect(
                try JSONDecoder().decode(
                    PronunciationAdvisoryEvidence.SelectionReason.self,
                    from: encoded) == reason)
        }
    }

    @Test func neuralShadowObservationDefaultsNilForOlderEvidence() throws {
        let olderSchemaFiveEvidence = Data(
            #"{"category":"lexical","selectedAuthority":"uncertain","alternatives":[],"selectionReason":"deterministicFallback","overrideSuppressedAutomation":false,"policyVersion":"policy-v1"}"#.utf8)
        let decodedOlder = try JSONDecoder().decode(
            PronunciationAdvisoryEvidence.self,
            from: olderSchemaFiveEvidence)
        #expect(decodedOlder.neuralShadowObservation == nil)
        #expect(decodedOlder.isValid())

    }

    @Test func everyNeuralObservationRoundTripsThroughTheLegacyEvidenceShape() throws {
        let existing = alternative(candidateID: "existing.shadow", ipa: "bæd")
        let outcomes = [
            evidence(
                alternatives: [neuralAlternative()],
                selectionReason: .shadowCandidate,
                observation: .candidate),
            evidence(
                selectionReason: .shadowAgreementSelected,
                observation: .agreementSelected),
            evidence(
                alternatives: [existing],
                selectionReason: .shadowAgreementExistingAlternative,
                observation: .agreementExistingAlternative),
            evidence(
                selectedCandidateID: "selected.fallback",
                selectionReason: .invalidCandidate,
                observation: .selectedCandidateIDConflict),
            evidence(
                alternatives: [existing],
                selectionReason: .invalidCandidate,
                observation: .existingAlternativeCandidateIDConflict),
            evidence(selectionReason: .invalidCandidate, observation: .invalidCandidate),
            evidence(selectionReason: .modelUnavailable, observation: .modelUnavailable),
            evidence(
                selectionReason: .modelIntegrityFailure,
                observation: .modelIntegrityFailure),
            evidence(
                selectionReason: .modelInferenceFailure,
                observation: .modelInferenceFailure),
        ]
        for outcome in outcomes {
            #expect(outcome.isValid())
            let encoded = try JSONEncoder().encode(outcome)
            let decoded = try JSONDecoder().decode(
                PronunciationAdvisoryEvidence.self,
                from: encoded)
            let legacy = try JSONDecoder().decode(LegacyAdvisoryEvidence.self, from: encoded)

            #expect(decoded == outcome)
            #expect(legacy.selectionReason.rawValue == outcome.selectionReason.rawValue)
            #expect(legacy.category == outcome.category)
            #expect(legacy.selectedAuthority == outcome.selectedAuthority)
            #expect(legacy.selectedCandidateID == outcome.selectedCandidateID)
            #expect(legacy.alternatives == outcome.alternatives)
            #expect(legacy.overrideSuppressedAutomation == outcome.overrideSuppressedAutomation)
            #expect(legacy.policyVersion == outcome.policyVersion)
        }
    }

    @Test func rejectsImpossibleNeuralObservationEvidenceCombinations() {
        let existing = alternative(candidateID: "existing.shadow", ipa: "bæd")
        let impossible = [
            evidence(selectionReason: .shadowCandidate, observation: .candidate),
            evidence(
                alternatives: [existing],
                selectionReason: .shadowCandidate,
                observation: .candidate),
            evidence(
                selectionReason: .shadowAgreementExistingAlternative,
                observation: .agreementExistingAlternative),
            evidence(
                selectionReason: .invalidCandidate,
                observation: .existingAlternativeCandidateIDConflict),
            evidence(
                selectionReason: .invalidCandidate,
                observation: .selectedCandidateIDConflict),
            evidence(
                selectionReason: .shadowAgreementExistingAlternative,
                observation: .agreementSelected),
            evidence(
                alternatives: [existing],
                selectionReason: .shadowAgreementSelected,
                observation: .agreementExistingAlternative),
            evidence(
                selectedCandidateID: "selected.fallback",
                selectionReason: .modelUnavailable,
                observation: .selectedCandidateIDConflict),
            evidence(
                alternatives: [existing],
                selectionReason: .shadowAgreementExistingAlternative,
                observation: .existingAlternativeCandidateIDConflict),
            evidence(
                selectedCandidateID: "selected.fallback",
                selectionReason: .invalidCandidate,
                observation: .selectedCandidateIDConflict,
                category: .acoustic),
            evidence(
                selectedCandidateID: "selected.fallback",
                selectionReason: .invalidCandidate,
                observation: .selectedCandidateIDConflict,
                selectedAuthority: .trusted),
            evidence(
                selectedCandidateID: "selected.fallback",
                selectionReason: .invalidCandidate,
                observation: .selectedCandidateIDConflict,
                overrideSuppressedAutomation: true),
            evidence(
                selectionReason: .modelIntegrityFailure,
                observation: .modelUnavailable),
            evidence(
                selectionReason: .modelInferenceFailure,
                observation: .modelIntegrityFailure),
            evidence(
                selectionReason: .invalidCandidate,
                observation: .modelInferenceFailure),
            evidence(
                selectionReason: .deterministicFallback,
                observation: .agreementSelected),
            evidence(
                selectedCandidateID: "selected.fallback",
                alternatives: [neuralAlternative()],
                selectionReason: .deterministicFallback,
                observation: .candidate),
            evidence(
                alternatives: [neuralAlternative()],
                selectionReason: .deterministicFallback,
                observation: .candidate,
                category: .contextual),
            evidence(
                alternatives: [neuralAlternative()],
                selectionReason: .deterministicFallback,
                observation: .candidate,
                selectedAuthority: .trusted),
            evidence(
                alternatives: [neuralAlternative()],
                selectionReason: .deterministicFallback,
                observation: .candidate,
                overrideSuppressedAutomation: true),
        ]

        for invalidEvidence in impossible {
            #expect(!invalidEvidence.isValid())
        }
    }

    @Test func acceptsAnalyzerProducedOrdinaryAndRawInvalidObservationShapes() {
        let existing = alternative(candidateID: "existing.shadow", ipa: "bæd")
        let valid = [
            evidence(selectionReason: .deterministicFallback, observation: nil),
            evidence(
                alternatives: [neuralAlternative()],
                selectionReason: .shadowCandidate,
                observation: .candidate),
            evidence(
                selectionReason: .shadowAgreementSelected,
                observation: .agreementSelected),
            evidence(
                alternatives: [existing],
                selectionReason: .shadowAgreementExistingAlternative,
                observation: .agreementExistingAlternative),
            evidence(
                selectedCandidateID: "selected.fallback",
                selectionReason: .invalidCandidate,
                observation: .selectedCandidateIDConflict),
            evidence(
                alternatives: [existing],
                selectionReason: .invalidCandidate,
                observation: .existingAlternativeCandidateIDConflict),
            evidence(selectionReason: .invalidCandidate, observation: .invalidCandidate),
            evidence(selectionReason: .modelUnavailable, observation: .modelUnavailable),
            evidence(
                selectionReason: .modelIntegrityFailure,
                observation: .modelIntegrityFailure),
            evidence(
                selectionReason: .modelInferenceFailure,
                observation: .modelInferenceFailure),
            evidence(
                alternatives: [neuralAlternative()],
                selectionReason: .deterministicFallback,
                observation: .candidate),
            evidence(
                alternatives: [existing],
                selectionReason: .deterministicFallback,
                observation: .agreementExistingAlternative),
            evidence(
                alternatives: [existing],
                selectionReason: .deterministicFallback,
                observation: .existingAlternativeCandidateIDConflict),
            evidence(
                selectionReason: .deterministicFallback,
                observation: .invalidCandidate),
            evidence(
                selectionReason: .deterministicFallback,
                observation: .modelUnavailable),
            evidence(
                selectionReason: .deterministicFallback,
                observation: .modelIntegrityFailure),
            evidence(
                selectionReason: .deterministicFallback,
                observation: .modelInferenceFailure),
        ]

        for validEvidence in valid {
            #expect(validEvidence.isValid())
        }
    }

    @Test func deterministicFallbackObservationRequiresInvalidNoSynthesisDecision() {
        let rawEvidence = evidence(
            alternatives: [neuralAlternative()],
            selectionReason: .deterministicFallback,
            observation: .candidate)
        let rawInvalid = PronunciationAuditDecision(
            blockID: "blk1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "xyzqwf",
            sourceWord: "Xyzqwf",
            sourceContext: "Xyzqwf",
            selectedIPA: "\u{0000}",
            kokoroTokenIDs: [],
            source: .fallback,
            ruleID: "g2p.fallback.xyzqwf",
            rationale: "fixture",
            candidateID: nil,
            advisoryEvidence: rawEvidence)
        let ordinary = PronunciationAuditDecision(
            blockID: "blk1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "xyzqwf",
            sourceWord: "Xyzqwf",
            sourceContext: "Xyzqwf",
            selectedIPA: "zizkwf",
            kokoroTokenIDs: [1],
            source: .fallback,
            ruleID: "g2p.fallback.xyzqwf",
            rationale: "fixture",
            candidateID: nil,
            advisoryEvidence: rawEvidence)

        #expect(rawEvidence.isValid(for: rawInvalid))
        #expect(!rawEvidence.isValid(for: ordinary))
    }

    @Test func alternativesAreCanonicalizedByStablePortableIdentity() {
        let evidence = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .uncertain,
            selectedCandidateID: "candidate.primary",
            alternatives: [
                alternative(candidateID: "candidate.b", ipa: "b"),
                alternative(candidateID: "candidate.a", ipa: "z"),
                alternative(candidateID: "candidate.a2", ipa: "a"),
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")

        #expect(evidence.alternatives.map(\.candidateID) == [
            "candidate.a",
            "candidate.a2",
            "candidate.b",
        ])
    }

    @Test func rejectsSelectedIdentityAndCanonicallyEquivalentAlternativeIPAs() {
        let selectedCollision = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: "candidate.primary",
            alternatives: [
                alternative(candidateID: "candidate.primary", ipa: "different")
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let normalizedIPACollision = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: "candidate.primary",
            alternatives: [
                alternative(candidateID: "candidate.a", ipa: " e\u{301} "),
                alternative(candidateID: "candidate.b", ipa: "é"),
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")

        #expect(!selectedCollision.isValid())
        #expect(!normalizedIPACollision.isValid())
    }

    @Test func evidenceOnlyAdvisoryMayReportTheSynthesizedIPAAsAnAlternative() {
        let evidence = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .uncertain,
            selectedCandidateID: nil,
            alternatives: [
                alternative(candidateID: "candidate.possible", ipa: "kˈɑntɛnt")
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let decision = PronunciationAuditDecision(
            blockID: "blk1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "content",
            sourceWord: "content",
            sourceContext: "content",
            selectedIPA: "kˈɑntɛnt",
            kokoroTokenIDs: [1],
            source: .fallback,
            ruleID: "fixture",
            rationale: "fixture",
            candidateID: nil,
            advisoryEvidence: evidence)

        #expect(evidence.isValid(for: decision))
    }
}
