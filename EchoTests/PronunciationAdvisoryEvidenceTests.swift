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
                        candidateID: "lexical.primary",
                        ipa: "lˈɛksɪkəl",
                        authority: .trusted,
                        validation: .eligible),
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
                        candidateID: "contextual.primary",
                        ipa: "kənˈtɛkstʃuəl",
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
    }

    @Test func alternativesAreCanonicalizedByStablePortableIdentity() {
        let evidence = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .qualified,
            selectedCandidateID: "candidate.b",
            alternatives: [
                alternative(candidateID: "candidate.b", ipa: "b"),
                alternative(candidateID: "candidate.a", ipa: "z"),
                alternative(candidateID: "candidate.a2", ipa: "a"),
            ],
            selectionReason: .deterministicFallback,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")

        #expect(evidence.alternatives.map(\.candidateID) == [
            "candidate.a",
            "candidate.a2",
            "candidate.b",
        ])
    }
}
