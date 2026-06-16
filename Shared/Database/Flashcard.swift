// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// When a flashcard should be triggered during playback.
enum FlashcardTriggerTiming: String, Codable, Sendable, CaseIterable {
    case beginning
    case end
    case manualOnly = "manualOnly"
}

/// GRDB record for the `flashcard` table with SM-2 / FSRS scheduling support.
struct Flashcard: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var frontText: String
    var backText: String
    var mediaTimestamp: TimeInterval
    var endTimestamp: TimeInterval?
    var triggerTiming: FlashcardTriggerTiming
    var nextReviewDate: String?
    var intervalDays: Int
    var easeFactor: Double
    var repetitions: Int
    var lastReviewedAt: String?
    var lastGrade: Int?
    var isEnabled: Bool
    var deckID: String?
    var tags: String?
    var mediaJSON: String?
    var sourceBlockID: String?
    var playlistPosition: Double?
    var createdAt: String?
    var modifiedAt: String?

    // MARK: FSRS fields (V16)
    var stability: Double?
    var difficulty: Double?
    /// Defaults to "normal" so callers that omit it never insert an explicit
    /// NULL into the `card_type NOT NULL` column (the schema default only applies
    /// when the column is omitted from the INSERT, not when it is NULL).
    var cardType: String? = "normal"
    var clozeIndex: Int?

    static let databaseTableName = "flashcard"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case frontText = "front_text"
        case backText = "back_text"
        case mediaTimestamp = "media_timestamp"
        case endTimestamp = "end_timestamp"
        case triggerTiming = "trigger_timing"
        case nextReviewDate = "next_review_date"
        case intervalDays = "interval_days"
        case easeFactor = "ease_factor"
        case repetitions
        case lastReviewedAt = "last_reviewed_at"
        case lastGrade = "last_grade"
        case isEnabled = "is_enabled"
        case deckID = "deck_id"
        case tags
        case mediaJSON = "media_json"
        case sourceBlockID = "source_block_id"
        case playlistPosition = "playlist_position"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case stability
        case difficulty
        case cardType = "card_type"
        case clozeIndex = "cloze_index"
    }
}
