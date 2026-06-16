// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct RealTimeEventRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var eventType: String
    var audiobookID: String?
    var mediaTimestamp: TimeInterval?
    var startedAt: String
    var endedAt: String?
    var title: String?
    var subtitle: String?
    var metadataJSON: String?
    var sourceItemID: String?
    var sourceItemType: String?

    static let databaseTableName = "real_time_event"

    enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case audiobookID = "audiobook_id"
        case mediaTimestamp = "media_timestamp"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case title
        case subtitle
        case metadataJSON = "metadata_json"
        case sourceItemID = "source_item_id"
        case sourceItemType = "source_item_type"
    }
}
