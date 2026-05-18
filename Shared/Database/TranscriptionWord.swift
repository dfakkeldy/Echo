import Foundation
import GRDB

/// GRDB record for the `transcription_word` table.
struct TranscriptionWord: Codable, FetchableRecord, MutablePersistableRecord {
    var segmentID: Int64
    var word: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var position: Int

    static let databaseTableName = "transcription_word"

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case word
        case startTime = "start_time"
        case endTime = "end_time"
        case position
    }
}
