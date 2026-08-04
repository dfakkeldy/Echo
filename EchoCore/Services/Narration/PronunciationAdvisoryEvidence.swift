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
        let normalizedPolicyVersion = policyVersion.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalizedPolicyVersion.isEmpty,
            normalizedPolicyVersion == policyVersion,
            alternatives == alternatives.sorted(by: Self.isOrderedBefore)
        else {
            return false
        }

        var candidateIDs: Set<String> = []
        if let selectedCandidateID {
            candidateIDs.insert(
                selectedCandidateID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var ipas: Set<String> = []
        for alternative in alternatives {
            let candidateID = alternative.candidateID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let ipa = Self.normalizedIPA(alternative.ipa)
            let source = alternative.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let alternativePolicyVersion = alternative.policyVersion.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !candidateID.isEmpty,
                candidateID == alternative.candidateID,
                !ipa.isEmpty,
                !source.isEmpty,
                source == alternative.source,
                !alternativePolicyVersion.isEmpty,
                alternativePolicyVersion == alternative.policyVersion,
                candidateIDs.insert(candidateID).inserted,
                ipas.insert(ipa).inserted
            else {
                return false
            }
        }
        return selectedCandidateID.map {
            !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? true
    }

    /// Schema-five evidence is meaningful only when its accepted identity is
    /// bound to the exact synthesis decision stored beside it.
    func isValid(for decision: PronunciationAuditDecision) -> Bool {
        guard isValid(),
            selectedCandidateID == decision.candidateID,
            selectedAuthority == Self.expectedAuthority(for: decision)
        else {
            return false
        }

        // Evidence-only advisories intentionally accept no candidate. The
        // synthesized decision IPA may still appear among the alternatives,
        // but it is not an advisory selection and therefore cannot collide.
        guard selectedCandidateID != nil else { return true }

        let selectedIPA = Self.normalizedIPA(decision.selectedIPA)
        guard !selectedIPA.isEmpty else { return false }
        return !alternatives.contains { alternative in
            Self.normalizedIPA(alternative.ipa) == selectedIPA
        }
    }

    private static func isOrderedBefore(_ lhs: Alternative, _ rhs: Alternative) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.candidateID != rhs.candidateID { return lhs.candidateID < rhs.candidateID }
        if lhs.ipa != rhs.ipa { return lhs.ipa < rhs.ipa }
        if lhs.authority != rhs.authority { return lhs.authority.rawValue < rhs.authority.rawValue }
        if lhs.validation != rhs.validation { return lhs.validation.rawValue < rhs.validation.rawValue }
        return lhs.policyVersion < rhs.policyVersion
    }

    private static func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expectedAuthority(
        for decision: PronunciationAuditDecision
    ) -> Authority {
        switch decision.source {
        case .fallback:
            return .uncertain
        case .contextualHomograph:
            return decision.contextualEvidence?.familyState == .graduated
                ? .qualified : .uncertain
        case .occurrenceOverride, .bookOverride, .globalOverride, .builtInOverride,
            .supplementalLexicon, .derivedMorphology, .monitoredLexicon:
            return .trusted
        }
    }
}

/// Issue-local metadata that cannot be reconstructed after advisory decisions
/// are grouped into one review row. The advisory receipt stays unchanged so it
/// can continue to round-trip through audit manifests and older decoders.
nonisolated struct PronunciationAdvisoryIssueEvidence: Codable, Equatable, Sendable {
    struct SelectedCandidate: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let source: PronunciationAuditDecision.Source
        let authority: PronunciationAdvisoryEvidence.Authority
        let validation: PronunciationAdvisoryEvidence.Validation
    }

    let advisoryEvidence: PronunciationAdvisoryEvidence
    let occurrenceCount: Int
    /// Builder-authored metadata for the accepted decision. Older advisory
    /// envelopes and evidence-only decisions legitimately omit this field.
    let selectedCandidate: SelectedCandidate?

    init(
        advisoryEvidence: PronunciationAdvisoryEvidence,
        occurrenceCount: Int,
        selectedCandidate: SelectedCandidate? = nil
    ) {
        self.advisoryEvidence = advisoryEvidence
        self.occurrenceCount = occurrenceCount
        self.selectedCandidate = selectedCandidate
    }

    func isValid() -> Bool {
        guard occurrenceCount > 0, advisoryEvidence.isValid() else { return false }
        guard let selectedCandidate else { return true }

        let candidateID = selectedCandidate.candidateID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIPA = Self.normalizedIPA(selectedCandidate.ipa)
        guard !candidateID.isEmpty,
            !selectedIPA.isEmpty,
            !selectedCandidate.source.rawValue.isEmpty,
            selectedCandidate.validation == .eligible,
            Self.authorityIsValid(
                selectedCandidate.authority,
                for: selectedCandidate.source),
            advisoryEvidence.selectedCandidateID == selectedCandidate.candidateID,
            advisoryEvidence.selectedAuthority == selectedCandidate.authority
        else {
            return false
        }

        return !advisoryEvidence.alternatives.contains { alternative in
            alternative.candidateID == selectedCandidate.candidateID
                || Self.normalizedIPA(alternative.ipa) == selectedIPA
        }
    }

    static func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func authorityIsValid(
        _ authority: PronunciationAdvisoryEvidence.Authority,
        for source: PronunciationAuditDecision.Source
    ) -> Bool {
        switch source {
        case .fallback:
            return authority == .uncertain
        case .contextualHomograph:
            return authority == .qualified || authority == .uncertain
        case .occurrenceOverride, .bookOverride, .globalOverride, .builtInOverride,
            .supplementalLexicon, .derivedMorphology, .monitoredLexicon:
            return authority == .trusted
        }
    }
}
