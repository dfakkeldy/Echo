import Foundation
import GRDB

/// GRDB record for the `transcription_segment` table.
struct TranscriptionRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    static let databaseTableName = "transcription_segment"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case text
    }
}
