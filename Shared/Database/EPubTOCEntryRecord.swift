import Foundation
import GRDB

/// A persisted row of the publisher-declared TOC tree (NCX `navPoint` /
/// EPUB 3 nav `ol` nesting), resolved to an imported block during EPUB import.
///
/// Rows form a tree via `parentID` and sort in reading order via `orderIndex`
/// (preorder position). `blockID` is the resolved navigation target — nil when
/// the entry's spine file produced no blocks.
struct EPubTOCEntryRecord: Identifiable, Equatable, Hashable, Sendable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var parentID: String?
    var orderIndex: Int
    var depth: Int
    var title: String
    var blockID: String?
    var spineIndex: Int?

    static let databaseTableName = "epub_toc_entry"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case parentID = "parent_id"
        case orderIndex = "order_index"
        case depth
        case title
        case blockID = "block_id"
        case spineIndex = "spine_index"
    }
}
