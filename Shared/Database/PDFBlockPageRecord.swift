// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

nonisolated struct PDFBlockPageRecord: Identifiable, Equatable, Codable, FetchableRecord,
    MutablePersistableRecord
{
    var id: Int64?
    var audiobookID: String
    var epubBlockID: String
    var pageIndex: Int
    /// JSON array with one entry per word of the block (`WordTokenizer` order):
    /// the word's page and its rectangles in PDF page space. Set only for PDFs
    /// imported from a read-along file (Schema V44); nil otherwise.
    var wordBoxes: String? = nil

    static let databaseTableName = "pdf_block_page"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case pageIndex = "page_index"
        case wordBoxes = "word_boxes"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
