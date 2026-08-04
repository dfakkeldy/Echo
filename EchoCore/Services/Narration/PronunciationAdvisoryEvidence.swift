// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Portable, advisory-only provenance for a pronunciation decision. This does
/// not select a pronunciation or alter audio generation; it records the
/// versioned alternatives that a later policy may safely inspect.
nonisolated struct PronunciationAdvisoryEvidence: Codable, Equatable, Sendable {
    enum Authority: String, Codable, Sendable {
        case trusted
        case qualified
        case uncertain
    }

    enum Category: String, Codable, Sendable {
        case lexical
        case contextual
        case acoustic
    }

    enum Validation: String, Codable, Sendable {
        case eligible
        case shadow
        case rejected
    }

    enum SelectionReason: String, Codable, Sendable {
        case occurrenceOverride
        case bookOverride
        case globalOverride
        case qualifiedDeterministicContext
        case trustedLexicon
        case qualifiedNeuralOOV
        case deterministicFallback
        case sourceDisagreement
        case shadowCandidate
        case invalidCandidate
        case modelUnavailable
        case modelIntegrityFailure
        case modelInferenceFailure
        case contextShadow
        case contextUnavailable
        case acousticRetryRejected
    }

    struct Alternative: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let source: String
        let authority: Authority
        let validation: Validation
        let policyVersion: String
    }

    let category: Category
    let selectedAuthority: Authority
    let selectedCandidateID: String?
    let alternatives: [Alternative]
    let selectionReason: SelectionReason
    let overrideSuppressedAutomation: Bool
    let policyVersion: String

    init(
        category: Category,
        selectedAuthority: Authority,
        selectedCandidateID: String?,
        alternatives: [Alternative],
        selectionReason: SelectionReason,
        overrideSuppressedAutomation: Bool,
        policyVersion: String
    ) {
        self.category = category
        self.selectedAuthority = selectedAuthority
        self.selectedCandidateID = selectedCandidateID
        self.alternatives = alternatives.sorted(by: Self.isOrderedBefore)
        self.selectionReason = selectionReason
        self.overrideSuppressedAutomation = overrideSuppressedAutomation
        self.policyVersion = policyVersion
    }

    /// Manifest validation is deliberately strict for schema 5. Older schemas
    /// predate this optional evidence and therefore bypass this gate.
    func isValid() -> Bool {
        guard !policyVersion.isEmpty,
            alternatives == alternatives.sorted(by: Self.isOrderedBefore)
        else {
            return false
        }

        var candidateIDs: Set<String> = []
        var ipas: Set<String> = []
        for alternative in alternatives {
            guard !alternative.candidateID.isEmpty,
                !alternative.ipa.isEmpty,
                !alternative.source.isEmpty,
                !alternative.policyVersion.isEmpty,
                candidateIDs.insert(alternative.candidateID).inserted,
                ipas.insert(alternative.ipa).inserted
            else {
                return false
            }
        }
        return selectedCandidateID.map { !$0.isEmpty } ?? true
    }

    private static func isOrderedBefore(_ lhs: Alternative, _ rhs: Alternative) -> Bool {
        if lhs.candidateID != rhs.candidateID { return lhs.candidateID < rhs.candidateID }
        if lhs.ipa != rhs.ipa { return lhs.ipa < rhs.ipa }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.authority != rhs.authority { return lhs.authority.rawValue < rhs.authority.rawValue }
        if lhs.validation != rhs.validation { return lhs.validation.rawValue < rhs.validation.rawValue }
        return lhs.policyVersion < rhs.policyVersion
    }
}
