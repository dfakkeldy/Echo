import Foundation
import GRDB

struct PlannedSessionRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var title: String
    var startTime: String
    var endTime: String
    var startPosition: Double?
    var endPosition: Double?
    var targetSpeed: Double
    var isCompleted: Bool
    var createdAt: String

    static let databaseTableName = "planned_session"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case title
        case startTime = "start_time"
        case endTime = "end_time"
        case startPosition = "start_position"
        case endPosition = "end_position"
        case targetSpeed = "target_speed"
        case isCompleted = "is_completed"
        case createdAt = "created_at"
    }
}
