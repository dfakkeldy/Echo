// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

enum BatchItemStatus: String, Codable {
    case queued, importing, transcribing, aligning, completed, failed
}

/// A persistent batch-processing queue entry. Survives app restart; `sourceBookmark`
/// is a macOS security-scoped bookmark so the file stays reachable after relaunch.
struct BatchQueueRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord
{
    var id: Int64?
    var audiobookID: String
    var sourceBookmark: Data
    var displayName: String
    var queuePosition: Int
    var status: BatchItemStatus
    var progress: Double
    var statusMessage: String?
    var errorMessage: String?
    var enqueuedAt: String
    var startedAt: String?
    var completedAt: String?

    static let databaseTableName = "batch_queue"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case sourceBookmark = "source_bookmark"
        case displayName = "display_name"
        case queuePosition = "queue_position"
        case status
        case progress
        case statusMessage = "status_message"
        case errorMessage = "error_message"
        case enqueuedAt = "enqueued_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
