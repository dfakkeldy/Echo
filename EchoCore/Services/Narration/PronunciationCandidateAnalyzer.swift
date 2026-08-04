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
