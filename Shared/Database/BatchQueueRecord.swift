// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

enum BatchItemStatus: String, Codable {
    case queued, importing, transcribing, aligning, completed, failed
}

/// Discriminates audiobook-alignment queue items (`.align`: import → transcribe →
/// align a narrated audiobook against its EPUB) from text-only EPUB narration
/// items (`.narrate`: synthesize on-device audio for an EPUB that has no audio).
/// Stored in `batch_queue.kind`.
enum BatchItemKind: String, Codable {
    case align
    case narrate

    /// Forward-compatible decode (CODE_AUDIT §5.5): a `kind` written by a future
    /// build decodes to `.align` (the safe default — re-process as a normal queue
    /// item) instead of throwing `DecodingError.dataCorrupted`, so an older build
    /// can still read a queue a newer build wrote. A bare `String`-backed enum's
    /// synthesized decoder crashes on any unrecognised value.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BatchItemKind(rawValue: raw) ?? .align
    }
}

/// A persistent batch-processing queue entry. Survives app restart; `sourceBookmark`
/// is a macOS security-scoped bookmark so the file stays reachable after relaunch.
struct BatchQueueRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord
{
    var id: Int64?
    var audiobookID: String
    var sourceBookmark: Data
    /// Security-scoped bookmark for the companion EPUB, captured at enqueue time
    /// while the user-selected folder's scope is still active. Nil when the
    /// audio file has no companion EPUB (behaves as before).
    var companionBookmark: Data?
    var displayName: String
    var queuePosition: Int
    var status: BatchItemStatus
    var progress: Double
    /// Whether this item is a narrated-audiobook alignment (`.align`, default) or
    /// a text-only EPUB narration synthesis (`.narrate`).
    var kind: BatchItemKind = .align
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
        case companionBookmark = "companion_bookmark"
        case displayName = "display_name"
        case queuePosition = "queue_position"
        case status
        case progress
        case kind
        case statusMessage = "status_message"
        case errorMessage = "error_message"
        case enqueuedAt = "enqueued_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
