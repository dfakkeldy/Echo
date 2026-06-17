// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// One rendered word within an EPUB block mapped to its audio `[start, end)`.
/// Materialized by `WordTimingMaterializer` on every (re)alignment. Rendered-word
/// granularity (whitespace split of the block's plain text), not normalized DTW
/// tokens — so the reader can index it directly by word position.
struct WordTimingRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord
{
    var id: Int64?
    var audiobookID: String
    var epubBlockID: String
    /// Zero-based index of this word within the block's whitespace-split plain text.
    var wordIndex: Int
    /// The rendered word (denormalized for debugging/inspection).
    var word: String
    var audioStartTime: TimeInterval
    var audioEndTime: TimeInterval
    /// 0.0–1.0. Interpolated words get a fixed medium value; DTW-refined words higher.
    var confidence: Double
    /// "interpolated" or "dtw".
    var source: String

    static let databaseTableName = "word_timing"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case wordIndex = "word_index"
        case word
        case audioStartTime = "audio_start_time"
        case audioEndTime = "audio_end_time"
        case confidence
        case source
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
