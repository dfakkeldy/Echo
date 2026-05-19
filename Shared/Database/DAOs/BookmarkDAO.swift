import Foundation
import GRDB

struct BookmarkDAO {
    let db: DatabaseWriter
    var timelineDAO: TimelineDAO? = nil

    func bookmarks(for audiobookID: String) throws -> [BookmarkRecord] {
        try db.read { db in
            try BookmarkRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("media_timestamp"))
                .fetchAll(db)
        }
    }

    func bookmark(id: String) throws -> BookmarkRecord? {
        try db.read { db in try BookmarkRecord.fetchOne(db, key: id) }
    }

    func insert(_ bookmark: BookmarkRecord) throws {
        var bm = bookmark
        try db.write { db in
            try bm.insert(db)
            try syncToTimeline(db, bookmark: bm)
        }
    }

    func update(_ bookmark: BookmarkRecord) throws {
        var bm = bookmark
        try db.write { db in
            try bm.save(db)
            try syncToTimeline(db, bookmark: bm)
        }
    }

    func delete(id: String) throws {
        try db.write { db in
            try BookmarkRecord.deleteOne(db, key: id)
            try TimelineItem
                .filter(Column("source_table") == "bookmark")
                .filter(Column("source_rowid") == id)
                .deleteAll(db)
        }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try BookmarkRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
            try TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("source_table") == "bookmark")
                .deleteAll(db)
        }
    }

    func count(for audiobookID: String) throws -> Int {
        try db.read { db in
            try BookmarkRecord
                .filter(Column("audiobook_id") == audiobookID)
                .fetchCount(db)
        }
    }

    private func syncToTimeline(_ db: Database, bookmark: BookmarkRecord) throws {
        let item = TimelineItem(
            id: "bookmark-\(bookmark.id)",
            audiobookID: bookmark.audiobookID,
            itemType: .bookmark,
            title: bookmark.title,
            subtitle: bookmark.note,
            textPayload: nil,
            imagePath: bookmark.imagePath,
            audioStartTime: bookmark.mediaTimestamp,
            audioEndTime: nil,
            epubSequenceIndex: nil,
            granularityLevel: .sentence,
            playlistPosition: bookmark.playlistPosition,
            isEnabled: bookmark.isEnabled,
            sourceTable: "bookmark",
            sourceRowid: bookmark.id,
            metadataJSON: bookmark.voiceMemoPath.map { "{\"voiceMemoPath\":\"\($0)\"}" },
            createdAt: bookmark.createdAt,
            modifiedAt: bookmark.modifiedAt
        )
        var mutable = item
        try mutable.save(db)
    }
}
