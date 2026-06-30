// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// One detected heard-vs-source divergence in generated narration audio.
/// Persisted per book; status survives relaunch. `id` is a UUID string.
struct NarrationQualityIssueRecord: Identifiable, Equatable, Codable, FetchableRecord,
    MutablePersistableRecord
{
    var id: String
    var audiobookID: String
    var sourceBlockID: String?
    var sourceWordStart: Int?
    var sourceWordEnd: Int?
    var audioStartTime: TimeInterval
    var audioEndTime: TimeInterval
    var expectedText: String
    var heardText: String
    var issueType: String
    var confidence: Double
    var suggestedFixJSON: String?
    var status: String
    var createdAt: String
    var resolvedAt: String?

    static let databaseTableName = "narration_quality_issue"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case sourceBlockID = "source_block_id"
        case sourceWordStart = "source_word_start"
        case sourceWordEnd = "source_word_end"
        case audioStartTime = "audio_start_time"
        case audioEndTime = "audio_end_time"
        case expectedText = "expected_text"
        case heardText = "heard_text"
        case issueType = "issue_type"
        case confidence
        case suggestedFixJSON = "suggested_fix_json"
        case status
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }
}

/// Closed vocabulary for `narration_quality_issue.issue_type`.
enum NarrationQAIssueType: String, Sendable {
    case pronunciation
    case omission
    case insertion
    case substitution
    case normalization
    case timingDrift
    case lowConfidence
}

/// Closed vocabulary for `narration_quality_issue.status`.
enum NarrationQAIssueStatus: String, Sendable {
    case open
    case resolved
    case ignored
}
