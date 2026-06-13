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
    var cardType: String?
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

/// SM-2 spaced repetition algorithm.
enum SpacedRepetitionService {
    static func apply(grade: Int, to card: Flashcard) -> Flashcard {
        var updated = card

        if grade >= 3 {
            // Correct response
            if updated.repetitions == 0 {
                updated.intervalDays = 1
            } else if updated.repetitions == 1 {
                updated.intervalDays = 6
            } else {
                updated.intervalDays = Int(Double(updated.intervalDays) * updated.easeFactor)
            }
            updated.repetitions += 1
        } else {
            // Incorrect response
            updated.repetitions = 0
            updated.intervalDays = 1
        }

        updated.easeFactor = max(1.3, updated.easeFactor + (0.1 - Double(5 - grade) * (0.08 + Double(5 - grade) * 0.02)))
        updated.lastReviewedAt = Date().ISO8601Format()
        updated.lastGrade = grade
        updated.modifiedAt = Date().ISO8601Format()

        if let nextDate = Calendar.current.date(byAdding: .day, value: updated.intervalDays, to: Date()) {
            updated.nextReviewDate = nextDate.ISO8601Format()
        }

        return updated
    }
}
