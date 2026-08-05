// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationAdvisoryEvidenceTests {
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
