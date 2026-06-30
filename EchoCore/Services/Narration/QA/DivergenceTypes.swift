// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A contiguous span where re-transcribed ("heard") narration diverges from the
/// source text. Pure value type produced by `NarrationQADetector`; consumed by a
/// `DivergenceClassifier`. Word indices are over `WordTokenizer.words(in: blockText)`.
struct DivergenceWindow: Equatable, Sendable {
    let blockID: String
    let expectedText: String
    let heardText: String
    let expectedWordStart: Int
    let expectedWordEnd: Int
    let audioStart: TimeInterval
    let audioEnd: TimeInterval
    /// Lowest ASR confidence observed in the window (1.0 when none reported).
    let confidence: Double
}

/// A classifier's verdict for one `DivergenceWindow`. The deterministic impl
/// always fills `issueType`/`confidence`; FM may also fill the suggested forms.
struct DivergenceClassification: Equatable, Sendable {
    let issueType: NarrationQAIssueType
    let suggestedSpokenForm: String?
    let suggestedIPA: String?
    let confidence: Double
}

/// Canonical Codable shape persisted in `narration_quality_issue.suggested_fix_json`.
/// Produced by `NarrationQAService.encodeFix` (this milestone) and decoded by
/// `ContributionPayloadFilter` (M5) — this is the single source of truth for that JSON.
/// Keep it minimal: `confidence`/`issueType` already live on the issue row's columns.
struct SuggestedFix: Codable, Equatable, Sendable {
    let spokenForm: String?
    let ipa: String?
}
