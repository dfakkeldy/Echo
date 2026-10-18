// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Derives a content-free `PronunciationContributionPayload` from a *resolved*
/// narration-QA pronunciation issue. This is the privacy gate (design doc Section 8):
/// it admits ONLY single-term pronunciation fixes and copies across just the
/// five allowed fields, so no surrounding prose, audio, paths, or book id can
/// ride along. Returns nil for anything that is not a clean, single-word,
/// resolved pronunciation fix with a suggested IPA.
enum ContributionPayloadFilter {
    static func payload(
        from issue: NarrationQualityIssueRecord,
        language: String,
        voiceModelVersion: String
    ) -> PronunciationContributionPayload? {
        // Only resolved issues carry a fix the user actually accepted.
        guard issue.status == NarrationQAIssueStatus.resolved.rawValue else { return nil }
        // Only pronunciation fixes contribute IPA.
        guard issue.issueType == NarrationQAIssueType.pronunciation.rawValue else { return nil }
        // The fix's IPA comes from the classifier output.
        guard
            let json = issue.suggestedFixJSON,
            let data = json.data(using: .utf8),
            let fix = try? JSONDecoder().decode(SuggestedFix.self, from: data),
            let ipa = fix.ipa,
            !ipa.isEmpty
        else { return nil }
        // The term is the expected (source) word. Enforce single-word — multi-word
        // expectedText could reconstruct private prose, so we drop it (use the
        // single canonical word-boundary authority).
        let words = WordTokenizer.words(in: issue.expectedText)
        guard words.count == 1, let term = words.first.map(String.init), !term.isEmpty
        else { return nil }
        return PronunciationContributionPayload(
            term: term,
            ipa: ipa,
            language: language,
            voiceModelVersion: voiceModelVersion,
            confidence: issue.confidence)
    }
}
