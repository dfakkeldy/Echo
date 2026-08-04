// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationAdvisoryIssueBuilderTests {
    private let createdAt = "2026-08-04T00:00:00Z"

    private func evidence(
        category: PronunciationAdvisoryEvidence.Category = .lexical,
        candidateID: String = "candidate.primary",
        ipa: String = "kˈɑntɛnt"
    ) -> PronunciationAdvisoryEvidence {
        PronunciationAdvisoryEvidence(
            category: category,
            selectedAuthority: .trusted,
            selectedCandidateID: candidateID,
            alternatives: [
                .init(
                    candidateID: "candidate.alternative",
                    ipa: ipa == "kˈɑntɛnt" ? "kəntˈɛnt" : "kˈɑntɛnt",
                    source: "fixture",
                    authority: .qualified,
                    validation: .shadow,
                    policyVersion: "policy-v1")
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
    }

    private func decision(
        blockID: String,
        wordStart: Int,
        normalizedWord: String = "content",
        sourceWord: String = "Content",
        advisoryEvidence: PronunciationAdvisoryEvidence,
        source: PronunciationAuditDecision.Source = .supplementalLexicon,
        sourceContext: String = "Private source sentence must not persist."
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordStart,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: sourceContext,
            selectedIPA: "kˈɑntɛnt",
            kokoroTokenIDs: [1, 2],
            source: source,
            ruleID: "private-rule-id",
            rationale: "private rationale",
            candidateID: advisoryEvidence.selectedCandidateID,
            advisoryEvidence: advisoryEvidence,
            bookRelativeAudioRange: .init(start: 4, end: 5),
            timingPrecision: .exactSynthesisWord)
    }

    @Test func groupsNonContextualAdvisoriesByNormalizedSpellingAndCandidate() throws {
        let advisory = evidence()
        let builder = PronunciationAdvisoryIssueBuilder()

        let records = builder.records(
            audiobookID: "book",
            decisions: [
                decision(blockID: "blk2", wordStart: 4, advisoryEvidence: advisory),
                decision(blockID: "blk1", wordStart: 2, advisoryEvidence: advisory),
            ],
            diagnostics: [],
            createdAt: createdAt)

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue)
        #expect(record.sourceBlockID == "blk1")
        #expect(record.sourceWordStart == 2)
        #expect(record.sourceWordEnd == 2)
        let fix = try JSONDecoder().decode(
            SuggestedFix.self,
            from: try #require(record.suggestedFixJSON?.data(using: .utf8)))
        #expect(fix == SuggestedFix(spokenForm: "Content", ipa: "kˈɑntɛnt"))
        let decodedEvidence = try JSONDecoder().decode(
            PronunciationAdvisoryIssueEvidence.self,
            from: try #require(record.evidenceJSON?.data(using: .utf8)))
        #expect(decodedEvidence.advisoryEvidence == advisory)
        #expect(decodedEvidence.occurrenceCount == 2)
        #expect(decodedEvidence.selectedCandidate?.candidateID == "candidate.primary")
        #expect(decodedEvidence.selectedCandidate?.ipa == "kˈɑntɛnt")
        #expect(decodedEvidence.selectedCandidate?.source == .supplementalLexicon)
        #expect(decodedEvidence.selectedCandidate?.authority == .trusted)
        #expect(decodedEvidence.selectedCandidate?.validation == .eligible)
        #expect(record.status == NarrationQAIssueStatus.open.rawValue)
    }

    @Test func keepsContextualAdvisoriesSeparateByLocationAndSelectedSense() {
        let advisory = evidence(category: .contextual)
        let builder = PronunciationAdvisoryIssueBuilder()

        let records = builder.records(
            audiobookID: "book",
            decisions: [
                decision(blockID: "blk1", wordStart: 2, advisoryEvidence: advisory),
                decision(blockID: "blk2", wordStart: 2, advisoryEvidence: advisory),
            ],
            diagnostics: [],
            createdAt: createdAt)

        #expect(records.count == 2)
        #expect(Set(records.map(\.sourceBlockID)) == ["blk1", "blk2"])
        #expect(Set(records.map(\.id)).count == 2)
    }

    @Test func derivesStableContentIDsRegardlessOfInputOrder() {
        let advisory = evidence()
        let first = decision(blockID: "blk1", wordStart: 2, advisoryEvidence: advisory)
        let second = decision(blockID: "blk2", wordStart: 4, advisoryEvidence: advisory)
        let builder = PronunciationAdvisoryIssueBuilder()

        let forward = builder.records(
            audiobookID: "book", decisions: [first, second], diagnostics: [], createdAt: createdAt)
        let reverse = builder.records(
            audiobookID: "book", decisions: [second, first], diagnostics: [], createdAt: createdAt)

        #expect(forward.map(\.id) == reverse.map(\.id))
    }

    @Test func stableIDChangesWithMaterialEvidenceButNotAlternativeOrdering() throws {
        func advisory(
            alternatives: [PronunciationAdvisoryEvidence.Alternative]
        ) -> PronunciationAdvisoryEvidence {
            PronunciationAdvisoryEvidence(
                category: .lexical,
                selectedAuthority: .trusted,
                selectedCandidateID: "candidate.primary",
                alternatives: alternatives,
                selectionReason: .sourceDisagreement,
                overrideSuppressedAutomation: false,
                policyVersion: "policy-v1")
        }
        let firstAlternative = PronunciationAdvisoryEvidence.Alternative(
            candidateID: "candidate.a",
            ipa: "kəntˈɛnt",
            source: "fixture-a",
            authority: .qualified,
            validation: .shadow,
            policyVersion: "policy-v1")
        let secondAlternative = PronunciationAdvisoryEvidence.Alternative(
            candidateID: "candidate.b",
            ipa: "kˈɑntənt",
            source: "fixture-b",
            authority: .uncertain,
            validation: .rejected,
            policyVersion: "policy-v1")
        let changedAlternative = PronunciationAdvisoryEvidence.Alternative(
            candidateID: "candidate.a",
            ipa: "kəntˈɪnt",
            source: "fixture-a",
            authority: .qualified,
            validation: .shadow,
            policyVersion: "policy-v1")
        let builder = PronunciationAdvisoryIssueBuilder()
        func id(for evidence: PronunciationAdvisoryEvidence) throws -> String {
            try #require(builder.records(
                audiobookID: "book",
                decisions: [decision(
                    blockID: "blk1", wordStart: 2, advisoryEvidence: evidence)],
                diagnostics: [],
                createdAt: createdAt).first?.id)
        }

        let forward = try id(for: advisory(alternatives: [firstAlternative, secondAlternative]))
        let reversed = try id(for: advisory(alternatives: [secondAlternative, firstAlternative]))
        let changed = try id(for: advisory(alternatives: [changedAlternative, secondAlternative]))

        #expect(forward == reversed)
        #expect(changed != forward)
    }

    @Test func recordsGenericDiagnosticsWithoutPrivateBookText() {
        let diagnostic = PronunciationAuditDiagnostic(
            reason: .qualityRejected,
            blockID: "blk1",
            chunkIndex: 3,
            expectedDisplayText: "Private source text.",
            reconstructedSpokenSurface: "Private spoken text.",
            fallbackHits: [.init(word: "Private", ipa: "pɹˈaɪvɪt")],
            finalPhonemes: "private-phonemes",
            reconstructedTokenPhonemes: "private-reconstructed")

        let record = PronunciationAdvisoryIssueBuilder().records(
            audiobookID: "book", decisions: [], diagnostics: [diagnostic], createdAt: createdAt).first

        #expect(record?.origin == NarrationQualityIssueOrigin.acoustic.rawValue)
        #expect(record?.sourceBlockID == "blk1")
        #expect(record?.sourceWordStart == nil)
        #expect(record?.sourceWordEnd == nil)
        #expect(record?.evidenceJSON == nil)
        #expect(record?.suggestedFixJSON == nil)
        #expect(record?.expectedText == "Pronunciation audit diagnostic")
        #expect(record?.heardText == PronunciationAuditDiagnostic.Reason.qualityRejected.rawValue)
    }

    @Test func decisionRowsDoNotCopyPrivateDecisionMetadataIntoIssueColumns() {
        let record = PronunciationAdvisoryIssueBuilder().records(
            audiobookID: "book",
            decisions: [decision(blockID: "blk1", wordStart: 2, advisoryEvidence: evidence())],
            diagnostics: [],
            createdAt: createdAt).first

        #expect(record?.expectedText == "Content")
        #expect(record?.heardText.isEmpty == true)
        #expect(record?.suggestedFixJSON?.contains("private") == false)
        #expect(record?.evidenceJSON?.contains("Private source sentence") == false)
    }

    @Test func omitsSuggestedFixWhenTheAdvisoryDidNotAcceptACandidate() throws {
        let undecided = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .uncertain,
            selectedCandidateID: nil,
            alternatives: [
                .init(
                    candidateID: "candidate.possible",
                    ipa: "kˈɑntɛnt",
                    source: "fixture",
                    authority: .qualified,
                    validation: .shadow,
                    policyVersion: "policy-v1")
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")

        let record = try #require(PronunciationAdvisoryIssueBuilder().records(
            audiobookID: "book",
            decisions: [
                decision(
                    blockID: "blk1",
                    wordStart: 2,
                    advisoryEvidence: undecided,
                    source: .fallback)
            ],
            diagnostics: [],
            createdAt: createdAt).first)

        #expect(record.suggestedFixJSON == nil)
        #expect(record.evidenceJSON != nil)
        let decodedEvidence = try JSONDecoder().decode(
            PronunciationAdvisoryIssueEvidence.self,
            from: try #require(record.evidenceJSON?.data(using: .utf8)))
        #expect(decodedEvidence.selectedCandidate == nil)
        #expect(decodedEvidence.isValid())
    }

    @Test func selectedCandidateCannotCollideWithAnAlternativeIdentityOrNormalizedIPA() {
        let selected = PronunciationAdvisoryIssueEvidence.SelectedCandidate(
            candidateID: "candidate.primary",
            ipa: " e\u{301} ",
            source: .supplementalLexicon,
            authority: .qualified,
            validation: .eligible)
        let matchingIdentity = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .qualified,
            selectedCandidateID: selected.candidateID,
            alternatives: [
                .init(
                    candidateID: selected.candidateID,
                    ipa: "different",
                    source: "fixture",
                    authority: .uncertain,
                    validation: .shadow,
                    policyVersion: "policy-v1")
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let matchingNormalizedIPA = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .qualified,
            selectedCandidateID: selected.candidateID,
            alternatives: [
                .init(
                    candidateID: "candidate.alternative",
                    ipa: "é",
                    source: "fixture",
                    authority: .uncertain,
                    validation: .shadow,
                    policyVersion: "policy-v1")
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")

        #expect(!PronunciationAdvisoryIssueEvidence(
            advisoryEvidence: matchingIdentity,
            occurrenceCount: 1,
            selectedCandidate: selected).isValid())
        #expect(!PronunciationAdvisoryIssueEvidence(
            advisoryEvidence: matchingNormalizedIPA,
            occurrenceCount: 1,
            selectedCandidate: selected).isValid())
    }

    @Test func selectedCandidateMustMatchTheAdvisoryIdentityAndAuthority() {
        let advisory = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: "candidate.primary",
            alternatives: [],
            selectionReason: .trustedLexicon,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")

        #expect(!PronunciationAdvisoryIssueEvidence(
            advisoryEvidence: advisory,
            occurrenceCount: 1,
            selectedCandidate: .init(
                candidateID: "candidate.other",
                ipa: "kˈɑntɛnt",
                source: .supplementalLexicon,
                authority: .trusted,
                validation: .eligible)).isValid())
        #expect(!PronunciationAdvisoryIssueEvidence(
            advisoryEvidence: advisory,
            occurrenceCount: 1,
            selectedCandidate: .init(
                candidateID: "candidate.primary",
                ipa: "kˈɑntɛnt",
                source: .supplementalLexicon,
                authority: .qualified,
                validation: .eligible)).isValid())
        #expect(!PronunciationAdvisoryIssueEvidence(
            advisoryEvidence: advisory,
            occurrenceCount: 1,
            selectedCandidate: .init(
                candidateID: "candidate.primary",
                ipa: "kˈɑntɛnt",
                source: .supplementalLexicon,
                authority: .trusted,
                validation: .shadow)).isValid())
    }

    @Test func rejectsEvidenceWhoseSelectedCandidateDoesNotMatchTheDecision() {
        let advisory = evidence(candidateID: "candidate.a")
        let mismatched = PronunciationAuditDecision(
            blockID: "blk1", wordStart: 0, wordEnd: 0, normalizedWord: "content",
            sourceWord: "Content", sourceContext: "private", selectedIPA: "kˈɑntɛnt",
            kokoroTokenIDs: [], source: .supplementalLexicon, ruleID: "r", rationale: "r",
            candidateID: "candidate.b", advisoryEvidence: advisory)
        #expect(PronunciationAdvisoryIssueBuilder().records(
            audiobookID: "book", decisions: [mismatched], diagnostics: [], createdAt: createdAt).isEmpty)
    }

    @Test func deduplicatesIdenticalDiagnostics() {
        let diagnostic = PronunciationAuditDiagnostic(
            reason: .decisionEvidenceMismatch, blockID: "blk", chunkIndex: 1,
            expectedDisplayText: "private", reconstructedSpokenSurface: "", fallbackHits: [])
        #expect(PronunciationAdvisoryIssueBuilder().records(
            audiobookID: "book", decisions: [], diagnostics: [diagnostic, diagnostic], createdAt: createdAt).count == 1)
    }
}
