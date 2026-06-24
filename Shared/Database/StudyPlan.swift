// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlan: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    var id: String
    var audiobookID: String
    var deckID: String?
    var cadenceUnit: String
    var newChapterLimit: Int
    var includeImages: Bool
    var queueModeDefault: String
    var catchUpPolicy: String
    var startDate: String
    var isPaused: Bool
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "study_plan"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case deckID = "deck_id"
        case cadenceUnit = "cadence_unit"
        case newChapterLimit = "new_chapter_limit"
        case includeImages = "include_images"
        case queueModeDefault = "queue_mode_default"
        case catchUpPolicy = "catch_up_policy"
        case startDate = "start_date"
        case isPaused = "is_paused"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
