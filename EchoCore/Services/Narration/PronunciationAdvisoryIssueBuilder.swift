// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Pure projection of immutable pronunciation-audit receipts into local,
/// non-blocking review rows. It deliberately copies no source context, rule,
/// rationale, token, or fallback metadata into the issue columns.
nonisolated struct PronunciationAdvisoryIssueBuilder: Sendable {
    func records(
        audiobookID: String,
        decisions: [PronunciationAuditDecision],
        diagnostics: [PronunciationAuditDiagnostic],
        createdAt: String
    ) -> [NarrationQualityIssueRecord] {
        let decisionRows = groupedDecisionRows(
            audiobookID: audiobookID,
            decisions: decisions,
            createdAt: createdAt)
        var seenDiagnostics: Set<String> = []
        var diagnosticRows: [NarrationQualityIssueRecord] = []
        for diagnostic in diagnostics {
            let chapter = diagnostic.chapterIndex.map { String($0) } ?? "none"
            let identity = "\(diagnostic.reason.rawValue)\u{1F}\(diagnostic.blockID)\u{1F}\(diagnostic.chunkIndex)\u{1F}\(chapter)"
            guard seenDiagnostics.insert(identity).inserted else { continue }
            diagnosticRows.append(
                diagnosticRow(audiobookID: audiobookID, diagnostic: diagnostic, createdAt: createdAt))
        }
        return (decisionRows + diagnosticRows).sorted { lhs, rhs in
            if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
            return lhs.id < rhs.id
        }
    }

    private func groupedDecisionRows(
        audiobookID: String,
        decisions: [PronunciationAuditDecision],
        createdAt: String
    ) -> [NarrationQualityIssueRecord] {
        let candidates = decisions.compactMap { decision -> DecisionCandidate? in
            guard let evidence = decision.advisoryEvidence, evidence.isValid() else { return nil }
            guard evidence.selectedCandidateID == decision.candidateID else { return nil }
            guard !isSpecializedFallbackOverlap(decision: decision, evidence: evidence) else {
                return nil
            }
            return DecisionCandidate(decision: decision, evidence: evidence)
        }
        let grouped = Dictionary(grouping: candidates) { candidate in
            candidate.groupKey
        }
        return grouped.values.compactMap { group in
            let orderedGroup = group.sorted(by: DecisionCandidate.isOrderedBefore)
            guard let representative = orderedGroup.first else {
                return nil
            }
            return decisionRow(
                audiobookID: audiobookID,
                candidate: representative,
                occurrenceIdentity: orderedGroup.map(\.locationIdentity)
                    .joined(separator: "\u{1E}"),
                createdAt: createdAt)
        }
    }

    private func isSpecializedFallbackOverlap(
        decision: PronunciationAuditDecision,
        evidence: PronunciationAdvisoryEvidence
    ) -> Bool {
        decision.source == .fallback
            && evidence.selectionReason == .deterministicFallback
            && evidence.alternatives.isEmpty
            && !decision.isEvidenceOnlyInvalidOutputAdvisory
    }

    private func decisionRow(
        audiobookID: String,
        candidate: DecisionCandidate,
        occurrenceIdentity: String,
        createdAt: String
    ) -> NarrationQualityIssueRecord? {
        guard
            let evidenceJSON = json(candidate.evidence),
            let origin = origin(for: candidate.evidence.category)
        else { return nil }
        let suggestedFixJSON = candidate.evidence.selectedCandidateID.flatMap { _ in
            json(SuggestedFix(spokenForm: candidate.decision.sourceWord, ipa: candidate.decision.selectedIPA))
        }
        let range = candidate.decision.bookRelativeAudioRange
            ?? candidate.decision.chapterRelativeAudioRange
        return NarrationQualityIssueRecord(
            id: stableID(
                audiobookID: audiobookID,
                origin: origin,
                identity: [candidate.groupKey, occurrenceIdentity]
                    .joined(separator: "\u{1F}")),
            audiobookID: audiobookID,
            sourceBlockID: candidate.decision.blockID,
            sourceWordStart: candidate.decision.wordStart,
            sourceWordEnd: candidate.decision.wordEnd,
            audioStartTime: range?.start ?? 0,
            audioEndTime: range.map { max($0.end, $0.start) } ?? 0,
            expectedText: candidate.decision.sourceWord,
            heardText: "",
            issueType: NarrationQAIssueType.pronunciation.rawValue,
            confidence: 1,
            suggestedFixJSON: suggestedFixJSON,
            origin: origin.rawValue,
            evidenceJSON: evidenceJSON,
            status: NarrationQAIssueStatus.open.rawValue,
            createdAt: createdAt,
            resolvedAt: nil)
    }

    private func diagnosticRow(
        audiobookID: String,
        diagnostic: PronunciationAuditDiagnostic,
        createdAt: String
    ) -> NarrationQualityIssueRecord {
        let origin: NarrationQualityIssueOrigin =
            diagnostic.reason == .qualityRejected ? .acoustic : .pronunciationPreflight
        let identity = [
            "diagnostic",
            diagnostic.reason.rawValue,
            diagnostic.blockID,
            String(diagnostic.chunkIndex),
            diagnostic.chapterIndex.map(String.init) ?? "none",
        ].joined(separator: "\u{1F}")
        return NarrationQualityIssueRecord(
            id: stableID(audiobookID: audiobookID, origin: origin, identity: identity),
            audiobookID: audiobookID,
            sourceBlockID: diagnostic.blockID,
            sourceWordStart: nil,
            sourceWordEnd: nil,
            audioStartTime: 0,
            audioEndTime: 0,
            expectedText: "Pronunciation audit diagnostic",
            heardText: diagnostic.reason.rawValue,
            issueType: NarrationQAIssueType.pronunciation.rawValue,
            confidence: 0,
            suggestedFixJSON: nil,
            origin: origin.rawValue,
            evidenceJSON: nil,
            status: NarrationQAIssueStatus.open.rawValue,
            createdAt: createdAt,
            resolvedAt: nil)
    }

    private func origin(
        for category: PronunciationAdvisoryEvidence.Category
    ) -> NarrationQualityIssueOrigin? {
        switch category {
        case .lexical, .contextual: .pronunciationPreflight
        case .acoustic: .acoustic
        }
    }

    private func stableID(
        audiobookID: String,
        origin: NarrationQualityIssueOrigin,
        identity: String
    ) -> String {
        let payload = ["pronunciation-advisory-v1", audiobookID, origin.rawValue, identity]
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "pron-advisory-\(digest.prefix(24))"
    }

    private func json<T: Encodable>(_ value: T) -> String? {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private struct DecisionCandidate {
        let decision: PronunciationAuditDecision
        let evidence: PronunciationAdvisoryEvidence

        var selectedCandidate: String {
            evidence.selectedCandidateID ?? decision.candidateID ?? decision.selectedIPA
        }

        var groupKey: String {
            switch evidence.category {
            case .contextual:
                [
                    evidence.category.rawValue,
                    decision.normalizedWord,
                    selectedCandidate,
                    decision.blockID,
                    String(decision.wordStart),
                    String(decision.wordEnd),
                ].joined(separator: "\u{1F}")
            case .lexical, .acoustic:
                [evidence.category.rawValue, decision.normalizedWord, selectedCandidate]
                    .joined(separator: "\u{1F}")
            }
        }

        /// Group identity deliberately excludes source locations for lexical and
        /// acoustic advisories, while persistent identity includes the ordered
        /// occurrences below. This keeps duplicate spellings grouped per render
        /// unit without allowing two separately materialized units to collide.
        var locationIdentity: String {
            [
                decision.blockID,
                String(decision.wordStart),
                String(decision.wordEnd),
            ].joined(separator: "\u{1F}")
        }

        static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.decision.blockID != rhs.decision.blockID {
                return lhs.decision.blockID < rhs.decision.blockID
            }
            if lhs.decision.wordStart != rhs.decision.wordStart {
                return lhs.decision.wordStart < rhs.decision.wordStart
            }
            return lhs.decision.wordEnd < rhs.decision.wordEnd
        }
    }
}
