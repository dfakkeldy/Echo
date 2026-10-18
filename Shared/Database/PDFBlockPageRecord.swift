// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct PDFBlockPageRecord: Identifiable, Equatable, Codable, FetchableRecord,
    MutablePersistableRecord
{
    var id: Int64?
    var audiobookID: String
    var epubBlockID: String
    var pageIndex: Int

    static let databaseTableName = "pdf_block_page"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case pageIndex = "page_index"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
