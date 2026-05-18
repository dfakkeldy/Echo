import Foundation
import GRDB

struct ChapterDAO {
    let db: DatabaseWriter

    func chapters(for audiobookID: String) throws -> [ChapterRecord] {
        try db.read { db in
            try ChapterRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("sort_order"))
                .fetchAll(db)
        }
    }

    func insertAll(_ chapters: [ChapterRecord], audiobookID: String) throws {
        try db.write { db in
            for var chapter in chapters {
                try chapter.insert(db)
            }
        }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try ChapterRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
