// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlanItem: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    var id: String
    var planID: String
    var flashcardID: String?
    var kind: String
    var chapterIndex: Int?
    var sourceBlockID: String?
    var ordinal: Int
    var introducedAt: String?
    var isEnabled: Bool
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "study_plan_item"

    enum CodingKeys: String, CodingKey {
        case id
        case planID = "plan_id"
        case flashcardID = "flashcard_id"
        case kind
        case chapterIndex = "chapter_index"
        case sourceBlockID = "source_block_id"
        case ordinal
        case introducedAt = "introduced_at"
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
