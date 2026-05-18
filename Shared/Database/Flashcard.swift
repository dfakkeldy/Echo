import Foundation
import GRDB

/// GRDB record for the `flashcard` table with SM-2 scheduling support.
struct Flashcard: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var frontText: String
    var backText: String
    var mediaTimestamp: TimeInterval
    var endTimestamp: TimeInterval?
    var triggerTiming: String
    var nextReviewDate: String?
    var intervalDays: Int
    var easeFactor: Double
    var repetitions: Int
    var lastReviewedAt: String?
    var lastGrade: Int?
    var isEnabled: Bool
    var playlistPosition: Double?

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
        case playlistPosition = "playlist_position"
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
        updated.lastReviewedAt = ISO8601DateFormatter().string(from: Date())
        updated.lastGrade = grade

        if let nextDate = Calendar.current.date(byAdding: .day, value: updated.intervalDays, to: Date()) {
            updated.nextReviewDate = ISO8601DateFormatter().string(from: nextDate)
        }

        return updated
    }
}
