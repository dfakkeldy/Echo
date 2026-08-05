// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Compares advisory-only pronunciation candidates without participating in
/// pronunciation selection. The selected seed remains the sole synthesis input.
nonisolated struct PronunciationCandidateAnalyzer: Sendable {
    let productionPack: EnglishPronunciationPack
    let auditPack: EnglishPronunciationAuditPack

    func evidence(
        for decision: PronunciationDecisionSeed,
        fallbackHits: [PronunciationFallbackHit],
        isWatchWord: Bool
    ) -> PronunciationAdvisoryEvidence? {
        let alternatives = advisoryAlternatives(
            for: decision.normalizedWord,
            excluding: decision.selectedIPA)
        guard isComparisonScoped(
            decision: decision,
            fallbackHits: fallbackHits,
            alternatives: alternatives,
            isWatchWord: isWatchWord)
        else {
            return nil
        }

        return PronunciationAdvisoryEvidence(
            category: decision.contextualEvidence != nil
                || ContextualPronunciationFamilies.family(for: decision.normalizedWord) != nil
                ? .contextual : .lexical,
            selectedAuthority: selectedAuthority(for: decision),
            selectedCandidateID: decision.candidateID,
            alternatives: alternatives,
            selectionReason: selectionReason(
                for: decision,
                hasAlternatives: !alternatives.isEmpty),
            overrideSuppressedAutomation: isOverride(decision.source)
                && !alternatives.isEmpty,
            policyVersion: auditPack.auditPackVersion)
    }

    /// Stage-three neural comparison is deliberately narrower than the general
    /// audit comparison scope: only a genuine deterministic fallback may invoke
    /// the model. Known-word disagreements remain deterministic and model-free.
    static func isNeuralOOVComparisonCandidate(
        _ decision: PronunciationAuditDecision
    ) -> Bool {
        decision.source == .fallback
            && !decision.normalizedWord.isEmpty
            && decision.advisoryEvidence != nil
    }

    static func attachingNeuralShadowResult(
        _ result: NeuralG2PShadowResult,
        to decision: PronunciationAuditDecision
    ) -> PronunciationAuditDecision {
        guard isNeuralOOVComparisonCandidate(decision), let evidence = decision.advisoryEvidence
        else { return decision }
        let preservesInvalidOutputReceipt = decision.isEvidenceOnlyInvalidOutputAdvisory

        let updatedEvidence: PronunciationAdvisoryEvidence
        switch result {
        case .candidate(let candidate):
            guard let alternative = neuralAlternative(for: candidate) else {
                updatedEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt ? evidence.selectionReason : .invalidCandidate,
                    neuralShadowObservation: .invalidCandidate,
                    in: evidence)
                break
            }
            let candidateIPA = normalizedIPA(alternative.ipa)
            let selectedIPA = normalizedIPA(decision.selectedIPA)
            if evidence.selectedCandidateID == alternative.candidateID {
                let agreesWithSelected = candidateIPA == selectedIPA
                updatedEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? evidence.selectionReason
                        : agreesWithSelected
                            ? .shadowAgreementSelected : .shadowSelectedCandidateIDConflict,
                    neuralShadowObservation: agreesWithSelected
                        ? .agreementSelected : .selectedCandidateIDConflict,
                    in: evidence)
                break
            }
            if let existing = evidence.alternatives.first(where: {
                $0.candidateID == alternative.candidateID
            }) {
                let agreesWithExistingAlternative = normalizedIPA(existing.ipa) == candidateIPA
                updatedEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? evidence.selectionReason
                        : agreesWithExistingAlternative
                            ? .shadowAgreementExistingAlternative
                            : .shadowExistingAlternativeCandidateIDConflict,
                    neuralShadowObservation: agreesWithExistingAlternative
                        ? .agreementExistingAlternative
                        : .existingAlternativeCandidateIDConflict,
                    in: evidence)
                break
            }
            if candidateIPA == selectedIPA {
                updatedEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? evidence.selectionReason : .shadowAgreementSelected,
                    neuralShadowObservation: .agreementSelected,
                    in: evidence)
                break
            }
            if evidence.alternatives.contains(where: {
                normalizedIPA($0.ipa) == candidateIPA
            }) {
                updatedEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? evidence.selectionReason : .shadowAgreementExistingAlternative,
                    neuralShadowObservation: .agreementExistingAlternative,
                    in: evidence)
                break
            }
            updatedEvidence = PronunciationAdvisoryEvidence(
                category: evidence.category,
                selectedAuthority: evidence.selectedAuthority,
                selectedCandidateID: evidence.selectedCandidateID,
                alternatives: evidence.alternatives + [alternative],
                selectionReason: preservesInvalidOutputReceipt
                    ? evidence.selectionReason : .shadowCandidate,
                overrideSuppressedAutomation: evidence.overrideSuppressedAutomation,
                policyVersion: evidence.policyVersion,
                neuralShadowObservation: .candidate)
        case .rejected(let failure):
            updatedEvidence = replacingSelectionReason(
                preservesInvalidOutputReceipt
                    ? evidence.selectionReason : selectionReason(for: failure),
                neuralShadowObservation: neuralShadowObservation(for: failure),
                in: evidence)
        }

        return replacingAdvisoryEvidence(updatedEvidence, in: decision)
    }

    private static func neuralAlternative(
        for candidate: NeuralG2PCandidate
    ) -> PronunciationAdvisoryEvidence.Alternative? {
        let candidateID = candidate.candidateID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ipa = normalizedIPA(candidate.ipa)
        let modelRevision = candidate.modelRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversionPolicy = candidate.conversionPolicyVersion.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let validationPolicy = candidate.validationPolicyVersion.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let selectionPolicy = candidate.selectionPolicyVersion.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !candidateID.isEmpty, candidateID == candidate.candidateID,
            !ipa.isEmpty,
            !modelRevision.isEmpty, modelRevision == candidate.modelRevision,
            !conversionPolicy.isEmpty, conversionPolicy == candidate.conversionPolicyVersion,
            !validationPolicy.isEmpty, validationPolicy == candidate.validationPolicyVersion,
            !selectionPolicy.isEmpty, selectionPolicy == candidate.selectionPolicyVersion,
            let vocabulary = try? KokoroPhonemeVocab(),
            (try? vocabulary.validatedIDs(forPhonemes: ipa)) != nil
        else {
            return nil
        }

        return PronunciationAdvisoryEvidence.Alternative(
            candidateID: candidateID,
            ipa: ipa,
            source:
                "mini-bart-g2p@\(modelRevision)|\(conversionPolicy)|\(validationPolicy)",
            authority: .uncertain,
            validation: .shadow,
            policyVersion: selectionPolicy)
    }

    private static func selectionReason(
        for failure: NeuralG2PFailure
    ) -> PronunciationAdvisoryEvidence.SelectionReason {
        switch failure {
        case .unavailable:
            return .modelUnavailable
        case .integrity:
            return .modelIntegrityFailure
        case .inference, .cancelled:
            return .modelInferenceFailure
        case .tokenization, .decoding, .emptyOutput, .unsupportedOutput:
            return .invalidCandidate
        }
    }

    private static func neuralShadowObservation(
        for failure: NeuralG2PFailure
    ) -> PronunciationAdvisoryEvidence.NeuralShadowObservation {
        switch failure {
        case .unavailable:
            return .modelUnavailable
        case .integrity:
            return .modelIntegrityFailure
        case .inference, .cancelled:
            return .modelInferenceFailure
        case .tokenization, .decoding, .emptyOutput, .unsupportedOutput:
            return .invalidCandidate
        }
    }

    private static func replacingSelectionReason(
        _ selectionReason: PronunciationAdvisoryEvidence.SelectionReason,
        neuralShadowObservation: PronunciationAdvisoryEvidence.NeuralShadowObservation,
        in evidence: PronunciationAdvisoryEvidence
    ) -> PronunciationAdvisoryEvidence {
        PronunciationAdvisoryEvidence(
            category: evidence.category,
            selectedAuthority: evidence.selectedAuthority,
            selectedCandidateID: evidence.selectedCandidateID,
            alternatives: evidence.alternatives,
            selectionReason: selectionReason,
            overrideSuppressedAutomation: evidence.overrideSuppressedAutomation,
            policyVersion: evidence.policyVersion,
            neuralShadowObservation: neuralShadowObservation)
    }

    private static func replacingAdvisoryEvidence(
        _ advisoryEvidence: PronunciationAdvisoryEvidence,
        in decision: PronunciationAuditDecision
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
            candidateID: decision.candidateID,
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

    private static func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func advisoryAlternatives(
        for normalizedWord: String,
        excluding selectedIPA: String
    ) -> [PronunciationAdvisoryEvidence.Alternative] {
        guard let vocabulary = try? KokoroPhonemeVocab() else { return [] }
        let selected = normalizedIPA(selectedIPA)
        let candidates = auditPack.alternatives(for: normalizedWord)
            .sorted { lhs, rhs in
                if lhs.sourceID != rhs.sourceID { return lhs.sourceID < rhs.sourceID }
                return lhs.candidateID < rhs.candidateID
            }

        var seenIPAs: Set<String> = []
        return candidates.compactMap { candidate in
            let ipa = normalizedIPA(candidate.ipa)
            guard !ipa.isEmpty,
                ipa != selected,
                seenIPAs.insert(ipa).inserted,
                (try? vocabulary.validatedIDs(forPhonemes: ipa)) != nil
            else {
                return nil
            }
            return PronunciationAdvisoryEvidence.Alternative(
                candidateID: candidate.candidateID,
                ipa: ipa,
                source: candidate.sourceID,
                authority: .uncertain,
                validation: .shadow,
                policyVersion: auditPack.auditPackVersion)
        }
    }

    private func isComparisonScoped(
        decision: PronunciationDecisionSeed,
        fallbackHits: [PronunciationFallbackHit],
        alternatives: [PronunciationAdvisoryEvidence.Alternative],
        isWatchWord: Bool
    ) -> Bool {
        if !alternatives.isEmpty || isWatchWord || decision.selectedIPA.isEmpty {
            return true
        }
        if decision.source == .fallback
            || fallbackHits.contains(where: {
                PronunciationAuditContext.normalizedWord($0.word) == decision.normalizedWord
            })
        {
            return true
        }
        if ContextualPronunciationFamilies.family(for: decision.normalizedWord) != nil {
            return true
        }
        if productionPack.hasExplicitCandidate(for: decision.normalizedWord)
            && productionPack.automaticCandidate(for: decision.normalizedWord) == nil
        {
            return true
        }
        // A title-cased token alone is ambiguous at a sentence boundary. It is
        // not sufficient evidence of a proper noun, so only an acronym gets
        // this no-other-signal comparison path.
        return isLikelyAcronym(decision.sourceWord)
            || PronunciationAuditContext.isRejectedRawG2POutput(decision.selectedIPA)
    }

    private func selectionReason(
        for decision: PronunciationDecisionSeed,
        hasAlternatives: Bool
    ) -> PronunciationAdvisoryEvidence.SelectionReason {
        switch decision.source {
        case .occurrenceOverride: return .occurrenceOverride
        case .bookOverride: return .bookOverride
        case .globalOverride: return .globalOverride
        case .builtInOverride: return hasAlternatives ? .sourceDisagreement : .trustedLexicon
        case .contextualHomograph:
            return decision.contextualEvidence?.familyState == .graduated
                ? .qualifiedDeterministicContext : .contextShadow
        case .fallback: return .deterministicFallback
        case .supplementalLexicon, .derivedMorphology, .monitoredLexicon:
            return hasAlternatives ? .sourceDisagreement : .trustedLexicon
        }
    }

    private func selectedAuthority(
        for decision: PronunciationDecisionSeed
    ) -> PronunciationAdvisoryEvidence.Authority {
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

    private func isOverride(_ source: PronunciationAuditDecision.Source) -> Bool {
        switch source {
        case .occurrenceOverride, .bookOverride, .globalOverride, .builtInOverride:
            return true
        case .contextualHomograph, .supplementalLexicon, .derivedMorphology,
            .monitoredLexicon, .fallback:
            return false
        }
    }

    private func isLikelyAcronym(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1 else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    private func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
