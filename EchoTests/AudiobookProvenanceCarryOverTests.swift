// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookProvenanceCarryOverTests {
    @Test func reingestPreservesProvenance() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/EchoTestBook")
        let id = folder.absoluteString

        // Seed a row as if ABSImportService had stamped provenance.
        let seeded = AudiobookRecord(
            id: id, title: "Book", author: "Author", duration: 10, fileCount: 1, addedAt: "seed",
            sourceType: "audiobookshelf", serverID: "srv1", remoteItemID: "item9",
            topicsJSON: "[\"Psychology\"]")
        try AudiobookDAO(db: db.writer).save(seeded)

        // A normal folder re-open must NOT wipe provenance.
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: 20)

        let after = try AudiobookDAO(db: db.writer).get(id)
        #expect(after?.sourceType == "audiobookshelf")
        #expect(after?.serverID == "srv1")
        #expect(after?.remoteItemID == "item9")
        #expect(after?.topicsJSON == "[\"Psychology\"]")
        // And the local-import case is still NULL by default.
        let localID = URL(fileURLWithPath: "/tmp/EchoLocalOnly").absoluteString
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: URL(fileURLWithPath: "/tmp/EchoLocalOnly"), tracks: [], duration: 5)
        #expect((try AudiobookDAO(db: db.writer).get(localID))?.sourceType == nil)
    }

    @Test func reingestPreservesLibraryEnrichment() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/EchoLibBook")
        let id = folder.absoluteString

        // Seed a row as if the Library rescan had enriched it: a cover written to
        // the LibraryCovers cache, an author for the "by author" axis, a narrator,
        // a sort key, and a source root linking it to a rescannable folder.
        var seeded = AudiobookRecord(
            id: id, title: "Folder Name", author: "Jane Doe", duration: 100, fileCount: 1,
            addedAt: "seed")
        seeded.coverArtPath = "deadbeef.jpg"
        seeded.narrator = "Reader X"
        seeded.authorSort = "doe, jane"
        seeded.sourceRootID = "root-1"
        try AudiobookDAO(db: db.writer).save(seeded)

        // A normal folder re-open (every play through loadFolder) must NOT wipe the
        // Library's enrichment — otherwise the shelf loses its cover, author, and
        // root link on the very next open. The loader still owns duration.
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: 120)

        let after = try AudiobookDAO(db: db.writer).get(id)
        #expect(after?.coverArtPath == "deadbeef.jpg")
        #expect(after?.narrator == "Reader X")
        #expect(after?.author == "Jane Doe")
        #expect(after?.authorSort == "doe, jane")
        #expect(after?.sourceRootID == "root-1")
        #expect(after?.duration == 120)
    }

    @Test func reingestKeepsABSTitleNotFolderName() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/ABSLibrary/uuid-123")
        let id = folder.absoluteString
        let seeded = AudiobookRecord(
            id: id, title: "Real ABS Title", author: "Real Author", duration: 10, fileCount: 1,
            addedAt: "seed", sourceType: "audiobookshelf", serverID: "s", remoteItemID: "r",
            topicsJSON: nil)
        try AudiobookDAO(db: db.writer).save(seeded)
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: 20)
        let after = try AudiobookDAO(db: db.writer).get(id)
        #expect(after?.title == "Real ABS Title")  // NOT "uuid-123"
        #expect(after?.author == "Real Author")
    }

    @Test func reingestWithoutLoadedDurationPreservesABSDuration() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/ABSLibrary/duration-item")
        let id = folder.absoluteString
        let seeded = AudiobookRecord(
            id: id, title: "ABS Duration", author: "Author", duration: 1200, fileCount: 1,
            addedAt: "seed", sourceType: "audiobookshelf", serverID: "s", remoteItemID: "r",
            topicsJSON: nil)
        try AudiobookDAO(db: db.writer).save(seeded)

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)
        #expect((try AudiobookDAO(db: db.writer).get(id))?.duration == 1200)

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: 0)
        #expect((try AudiobookDAO(db: db.writer).get(id))?.duration == 1200)
    }

    @Test func loadedDurationReplacesPreservedABSDuration() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/ABSLibrary/current-duration-item")
        let id = folder.absoluteString
        let seeded = AudiobookRecord(
            id: id, title: "ABS Duration", author: "Author", duration: 1200, fileCount: 1,
            addedAt: "seed", sourceType: "audiobookshelf", serverID: "s", remoteItemID: "r",
            topicsJSON: nil)
        try AudiobookDAO(db: db.writer).save(seeded)

        TimelineIngestionService.updateAudiobookDuration(
            db: db, audiobookID: id, duration: 1305.5)

        #expect((try AudiobookDAO(db: db.writer).get(id))?.duration == 1305.5)
    }
}
