// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct PDFBlockPageDAO {
    let db: DatabaseWriter

    func insert(_ record: PDFBlockPageRecord) throws {
        var mutable = record
        try db.write { db in try mutable.insert(db) }
    }

    func insertAll(_ records: [PDFBlockPageRecord]) throws {
        try db.write { db in
            for var r in records { try r.insert(db) }
        }
    }

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try PDFBlockPageRecord.filter(Column("audiobook_id") == audiobookID).deleteAll(db)
        }
    }

    func pageIndex(for audiobookID: String, epubBlockID: String) throws -> Int? {
        try db.read { db in
            try PDFBlockPageRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("epub_block_id") == epubBlockID)
                .fetchOne(db)?.pageIndex
        }
    }

    func rows(for audiobookID: String) throws -> [PDFBlockPageRecord] {
        try db.read { db in
            try PDFBlockPageRecord.filter(Column("audiobook_id") == audiobookID).fetchAll(db)
        }
    }
}
