// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// GRDB record for the `voice_memo` table (V24). A standalone voice memo: an
/// `.m4a` file (`file_path`, relative to the book folder) plus this row. Distinct
/// from `bookmark.voice_memo_path`, which is an attachment on a bookmark.
struct VoiceMemoRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Hashable,
    Sendable
{
    var id: String
    var audiobookID: String
    /// FK to `epub_block.id` for document-order feed positioning; nil → positioned
    /// by `mediaTimestamp` only.
    var epubBlockID: String?
    var mediaTimestamp: TimeInterval
    var filePath: String
    var duration: TimeInterval?
    var isEnabled: Bool
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "voice_memo"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case mediaTimestamp = "media_timestamp"
        case filePath = "file_path"
        case duration
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
