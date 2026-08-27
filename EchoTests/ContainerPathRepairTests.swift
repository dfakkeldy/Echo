// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Audiobook identity is the folder's absolute `file://` URL, but iOS moves
/// the app's data container on updates and reinstalls. These tests fabricate a
/// database keyed under a dead container path, place the real folders under a
/// scratch "current" root, and verify the open-time repair re-keys rows,
/// children, and embedded ids onto the current path — absorbing placeholder
/// rows created at the new path in the meantime.
@Suite struct ContainerPathRepairTests {
    private static let marker = "/Library/Application%20Support/"
    /// Dead prefixes must look container-managed ("/Containers/"): the repair
    /// deliberately ignores non-container paths so it can never rebase a
    /// foreign database's books onto the operator's home folders.
    private static let deadPrefix =
        "file:///dead/Containers/Data/Application/OLD-AAAA/Library/Application%20Support/"
    private static let deadRootPath = "/dead/Containers/Data/Application/OLD-AAAA/"

    /// A scratch root whose URL ends with the app-support marker, so the
    /// path-form rewrites (`Anchor.containerRootPath`) are exercised exactly
    /// as they would be against a real container.
    private func makeScratchRoot() throws -> (container: URL, appSupport: URL) {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "ContainerPathRepairTests-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        let appSupport = container.appending(
            path: "Library/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true)
        return (container, appSupport)
    }

    private func makeDatabase() throws -> DatabaseQueue {
        let writer = try DatabaseQueue()
        try DatabaseService.makeMigrator().migrate(writer)
        return writer
    }

    private func anchor(appSupport: URL) -> ContainerPathRepair.Anchor {
        ContainerPathRepair.Anchor(marker: Self.marker, root: appSupport)
    }

    private func makeBookFolder(under appSupport: URL, item: String) throws -> String {
        let folder = appSupport.appending(path: "ABSLibrary/\(item)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "audio.mp3"))
        return appSupport.absoluteString + "ABSLibrary/\(item)/"
    }

    @Test func rebasedIDRebasesOntoCurrentAnchorRoot() throws {
        let (container, appSupport) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let old = Self.deadPrefix + "ABSLibrary/item-1/"
        let rebased = ContainerPathRepair.rebasedID(old, anchors: [anchor(appSupport: appSupport)])
        #expect(rebased == appSupport.absoluteString + "ABSLibrary/item-1/")
    }

    @Test func rebasedIDReturnsNilWithoutMarker() throws {
        let (container, appSupport) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let rebased = ContainerPathRepair.rebasedID(
            "file:///dead/Somewhere/Else/book/", anchors: [anchor(appSupport: appSupport)])
        #expect(rebased == nil)
    }

    @Test func strandedBookIsRekeyedWithChildrenAndEmbeddedIDs() throws {
        let (container, appSupport) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let old = Self.deadPrefix + "ABSLibrary/item-1/"
        let new = try makeBookFolder(under: appSupport, item: "item-1")
        let oldImagePath =
            Self.deadRootPath + "Library/Application Support/EPUBAssets/book/cover-1.png"

        let writer = try makeDatabase()
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook
                        (id, title, duration, added_at, source_type, server_id, remote_item_id,
                         cover_art_path)
                    VALUES (?, 'Real Title', 3600, '2026-01-01T00:00:00Z', 'audiobookshelf',
                            'srv-1', 'item-1', 'missing-cover.jpg')
                    """,
                arguments: [old])
            try db.execute(
                sql: """
                    INSERT INTO track (id, audiobook_id, title, duration, file_path)
                    VALUES (?, ?, 'audio', 0, ?)
                    """,
                arguments: [old + "audio.mp3", old, old + "audio.mp3"])
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                        (id, audiobook_id, spine_href, spine_index, block_index,
                         sequence_index, block_kind, image_path)
                    VALUES (?, ?, 'ch1.xhtml', 0, 0, 0, 'image', ?)
                    """,
                arguments: ["epub-\(old)-s0-b0", old, oldImagePath])
            try db.execute(
                sql: """
                    INSERT INTO word_timing
                        (audiobook_id, epub_block_id, word_index, word,
                         audio_start_time, audio_end_time)
                    VALUES (?, ?, 0, 'hello', 0, 1)
                    """,
                arguments: [old, "epub-\(old)-s0-b0"])
            try db.execute(
                sql: """
                    INSERT INTO note (id, audiobook_id, text, media_timestamp)
                    VALUES ('note-1', ?, 'kept', 12)
                    """,
                arguments: [old])
            try db.execute(
                sql: """
                    INSERT INTO playback_state (audiobook_id, last_position, last_played_at)
                    VALUES (?, 640, '2026-02-01T00:00:00Z')
                    """,
                arguments: [old])
        }

        let repaired = try ContainerPathRepair.repairStrandedBooks(
            writer: writer,
            anchors: [anchor(appSupport: appSupport)],
            coversDirectory: appSupport.appending(path: "Covers", directoryHint: .isDirectory))
        #expect(repaired == 1)

        try writer.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM audiobook")
            #expect(ids == [new])
            let title = try String.fetchOne(
                db, sql: "SELECT title FROM audiobook WHERE id = ?", arguments: [new])
            #expect(title == "Real Title")
            // The stored cover filename no longer resolves after a reinstall
            // wipes Caches, so the repair clears it for re-extraction.
            let cover = try String.fetchOne(
                db, sql: "SELECT cover_art_path FROM audiobook WHERE id = ?", arguments: [new])
            #expect(cover == nil)
            let blockID = try String.fetchOne(
                db, sql: "SELECT id FROM epub_block WHERE audiobook_id = ?", arguments: [new])
            #expect(blockID == "epub-\(new)-s0-b0")
            // Absolute asset paths move container-root-to-root: the suffix
            // (including the old-id-derived asset folder name) is preserved.
            let imagePath = try String.fetchOne(
                db, sql: "SELECT image_path FROM epub_block WHERE audiobook_id = ?",
                arguments: [new])
            #expect(
                imagePath == container.path
                    + "/Library/Application Support/EPUBAssets/book/cover-1.png")
            let timingBlock = try String.fetchOne(
                db, sql: "SELECT epub_block_id FROM word_timing WHERE audiobook_id = ?",
                arguments: [new])
            #expect(timingBlock == "epub-\(new)-s0-b0")
            let trackPath = try String.fetchOne(
                db, sql: "SELECT file_path FROM track WHERE audiobook_id = ?", arguments: [new])
            #expect(trackPath == new + "audio.mp3")
            let noteCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM note WHERE audiobook_id = ?", arguments: [new])
            #expect(noteCount == 1)
            let position = try Double.fetchOne(
                db, sql: "SELECT last_position FROM playback_state WHERE audiobook_id = ?",
                arguments: [new])
            #expect(position == 640)
        }

        // Idempotent: a second pass finds nothing stranded.
        let second = try ContainerPathRepair.repairStrandedBooks(
            writer: writer, anchors: [anchor(appSupport: appSupport)])
        #expect(second == 0)
    }

    @Test func strandedBookAbsorbsPlaceholderCreatedAtCurrentPath() throws {
        let (container, appSupport) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let old = Self.deadPrefix + "ABSLibrary/item-2/"
        let new = try makeBookFolder(under: appSupport, item: "item-2")

        let writer = try makeDatabase()
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook
                        (id, title, author, duration, added_at, source_type, server_id,
                         remote_item_id)
                    VALUES (?, 'Real Title', 'Real Author', 3600, '2026-01-01T00:00:00Z',
                            'audiobookshelf', 'srv-1', 'item-2')
                    """,
                arguments: [old])
            try db.execute(
                sql: """
                    INSERT INTO track (id, audiobook_id, title, duration, file_path)
                    VALUES (?, ?, 'audio', 0, ?)
                    """,
                arguments: [old + "audio.mp3", old, old + "audio.mp3"])
            try db.execute(
                sql: """
                    INSERT INTO playback_state (audiobook_id, last_position, last_played_at)
                    VALUES (?, 640, '2026-02-01T00:00:00Z')
                    """,
                arguments: [old])
            // The placeholder the player wrote when it re-opened the folder at
            // its new path: folder-name title, no provenance, a track row with
            // a DIFFERENT filename (so no id re-converges), a bookmark
            // pointing at that track, a user note, and a newer playback state.
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, 'item-2', 0, '2026-08-20T00:00:00Z')
                    """,
                arguments: [new])
            try db.execute(
                sql: """
                    INSERT INTO track (id, audiobook_id, title, duration, file_path)
                    VALUES (?, ?, 'other', 0, ?)
                    """,
                arguments: [new + "other.mp3", new, new + "other.mp3"])
            try db.execute(
                sql: """
                    INSERT INTO bookmark (id, audiobook_id, track_id, title, media_timestamp)
                    VALUES ('bm-1', ?, ?, 'placeholder bookmark', 9)
                    """,
                arguments: [new, new + "other.mp3"])
            try db.execute(
                sql: """
                    INSERT INTO note (id, audiobook_id, text, media_timestamp)
                    VALUES ('note-placeholder', ?, 'placeholder-era note', 5)
                    """,
                arguments: [new])
            try db.execute(
                sql: """
                    INSERT INTO playback_state (audiobook_id, last_position, last_played_at)
                    VALUES (?, 3, '2026-08-21T00:00:00Z')
                    """,
                arguments: [new])
        }

        let repaired = try ContainerPathRepair.repairStrandedBooks(
            writer: writer, anchors: [anchor(appSupport: appSupport)])
        #expect(repaired == 1)

        try writer.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM audiobook")
            #expect(ids == [new])
            let title = try String.fetchOne(
                db, sql: "SELECT title FROM audiobook WHERE id = ?", arguments: [new])
            #expect(title == "Real Title")
            let author = try String.fetchOne(
                db, sql: "SELECT author FROM audiobook WHERE id = ?", arguments: [new])
            #expect(author == "Real Author")
            let remoteItemID = try String.fetchOne(
                db, sql: "SELECT remote_item_id FROM audiobook WHERE id = ?", arguments: [new])
            #expect(remoteItemID == "item-2")
            // The stranded row's track content replaced the placeholder's copy.
            let trackPaths = try String.fetchAll(
                db, sql: "SELECT file_path FROM track WHERE audiobook_id = ?", arguments: [new])
            #expect(trackPaths == [new + "audio.mp3"])
            // Placeholder-era user data survives the merge; the bookmark's
            // reference to the deleted placeholder track is nulled so the
            // deferred FK check passes.
            let note = try String.fetchOne(
                db, sql: "SELECT text FROM note WHERE audiobook_id = ?", arguments: [new])
            #expect(note == "placeholder-era note")
            let bookmarkTrack = try String.fetchOne(
                db, sql: "SELECT track_id FROM bookmark WHERE id = 'bm-1'")
            #expect(bookmarkTrack == nil)
            let bookmarkCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM bookmark WHERE audiobook_id = ?", arguments: [new])
            #expect(bookmarkCount == 1)
            // The more recently played state wins (the placeholder's).
            let position = try Double.fetchOne(
                db, sql: "SELECT last_position FROM playback_state WHERE audiobook_id = ?",
                arguments: [new])
            #expect(position == 3)
        }
    }

    @Test func multipleStrandedGenerationsCollapseOntoOneRow() throws {
        let (container, appSupport) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let oldA =
            "file:///dead/Containers/Data/Application/OLD-AAAA/Library/Application%20Support/"
            + "ABSLibrary/item-4/"
        let oldB =
            "file:///dead/Containers/Data/Application/OLD-BBBB/Library/Application%20Support/"
            + "ABSLibrary/item-4/"
        let new = try makeBookFolder(under: appSupport, item: "item-4")

        let writer = try makeDatabase()
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, 'Older Generation', 100, '2026-01-01T00:00:00Z')
                    """,
                arguments: [oldA])
            try db.execute(
                sql: """
                    INSERT INTO note (id, audiobook_id, text, media_timestamp)
                    VALUES ('note-a', ?, 'from generation A', 1)
                    """,
                arguments: [oldA])
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, 'Newer Generation', 200, '2026-06-01T00:00:00Z')
                    """,
                arguments: [oldB])
            try db.execute(
                sql: """
                    INSERT INTO note (id, audiobook_id, text, media_timestamp)
                    VALUES ('note-b', ?, 'from generation B', 2)
                    """,
                arguments: [oldB])
        }

        let repaired = try ContainerPathRepair.repairStrandedBooks(
            writer: writer, anchors: [anchor(appSupport: appSupport)])
        #expect(repaired == 2)

        try writer.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM audiobook")
            #expect(ids == [new])
            // Oldest-first processing means the newest generation's metadata
            // lands last and wins.
            let title = try String.fetchOne(
                db, sql: "SELECT title FROM audiobook WHERE id = ?", arguments: [new])
            #expect(title == "Newer Generation")
            let notes = try String.fetchAll(
                db,
                sql: "SELECT text FROM note WHERE audiobook_id = ? ORDER BY media_timestamp",
                arguments: [new])
            #expect(notes == ["from generation A", "from generation B"])
        }
    }

    @Test func booksWhoseFoldersStillExistAreUntouched() throws {
        let (container, appSupport) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let liveID = try makeBookFolder(under: appSupport, item: "item-3")

        let writer = try makeDatabase()
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, 'Live Book', 60, '2026-01-01T00:00:00Z')
                    """,
                arguments: [liveID])
        }
        let repaired = try ContainerPathRepair.repairStrandedBooks(
            writer: writer, anchors: [anchor(appSupport: appSupport)])
        #expect(repaired == 0)
        try writer.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM audiobook")
            #expect(ids == [liveID])
        }
    }

    @Test func nonContainerPathsAreNeverRebased() throws {
        let (container, appSupport) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        _ = try makeBookFolder(under: appSupport, item: "item-5")
        // Same durable suffix, but the prefix is not container-managed (an
        // external volume, or a foreign database opened via echo-cli). The
        // folder is gone and the suffix exists under the current root, yet
        // the repair must leave it alone.
        let foreign =
            "file:///Volumes/Archive/Library/Application%20Support/ABSLibrary/item-5/"

        let writer = try makeDatabase()
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, 'Foreign Book', 60, '2026-01-01T00:00:00Z')
                    """,
                arguments: [foreign])
        }
        let repaired = try ContainerPathRepair.repairStrandedBooks(
            writer: writer, anchors: [anchor(appSupport: appSupport)])
        #expect(repaired == 0)
        try writer.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM audiobook")
            #expect(ids == [foreign])
        }
    }
}
