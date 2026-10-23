// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
import Testing
import UIKit
@testable import Echo

@MainActor
struct AuditRemediationTests {
    @Test func normalizationCachePreservesConcurrentOutputs() async {
        let samples = [
            ("Dr. Smith arrived.", "Doctor Smith arrived."),
            ("See e.g. chapter 3.", "See for example chapter 3."),
            ("Chapter IV begins.", "Chapter 4 begins."),
            ("Completion hit 100%.", "Completion hit one hundred percent."),
        ]
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<64 {
                let (input, expected) = samples[i % samples.count]
                group.addTask { TextNormalizer.normalize(input) == expected }
            }
            for await equal in group { #expect(equal) }
        }
    }

    @Test func librarySwitchRestoresBookmarksAndWidgetMergeSurvivesReopen() async throws {
        let database = try DatabaseService(inMemory: ())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audit-switch-\(UUID())")
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for url in [a, b] {
            try AudiobookDAO(db: database.writer).insert(
                AudiobookRecord(
                    id: url.absoluteString, title: url.lastPathComponent, duration: 0,
                    addedAt: "2026-10-22T00:00:00Z"))
        }
        let original = Bookmark(title: "A only", folderKey: a.absoluteString, timestamp: 1)
        try BookmarkStore.replaceBookmarks([original], for: a.absoluteString, database: database)
        let model = PlayerModel()
        model.databaseService = database
        model.openLibraryBook(LibraryOpenTarget(url: a, scopedRoot: nil))
        #expect(model.bookmarkStore.bookmarks.map(\.id) == [original.id])
        model.openLibraryBook(LibraryOpenTarget(url: b, scopedRoot: nil))
        #expect(model.bookmarkStore.bookmarks.isEmpty)
        let incoming = Bookmark(title: "Widget for A", folderKey: a.absoluteString, timestamp: 2)
        let suite = "audit-widget-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "bookmarks_" + a.absoluteString
        defaults.set(try JSONEncoder().encode([incoming]), forKey: key)
        for task in model.drainPendingWidgetBookmarks(from: defaults) { await task.value }
        #expect(defaults.data(forKey: key) == nil)
        model.openLibraryBook(LibraryOpenTarget(url: a, scopedRoot: nil))
        #expect(Set(model.bookmarkStore.bookmarks.map(\.id)) == [original.id, incoming.id])
    }

    @Test func searchSupersedesBookOpenReload() async throws {
        let database = try DatabaseService(inMemory: ())
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 60)")
            try db.execute(
                sql:
                    "INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, text, chapter_index, is_hidden) VALUES ('p', 'book', 'chapter.xhtml', 0, 0, 0, 'paragraph', 'Original paragraph', 0, 0)"
            )
        }
        let model = ReaderFeedViewModel(audiobookID: "book", db: database.writer)
        model.reloadOffMain()
        model.searchQuery = "absent"
        await model.waitForReload()
        #expect(model.searchQuery == "absent")
        #expect(model.displaySections.flatMap(\.items).isEmpty)
        model.searchQuery = nil
        await model.waitForReload()
        await model.waitForReload()
        #expect(model.sections.flatMap(\.items).contains { $0.id == "b-p" })
    }

    @Test func searchingDuringBookOpenStillInitializesPlaybackTimings() async throws {
        let database = try DatabaseService(inMemory: ())
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 60)")
            try db.execute(
                sql:
                    "INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, text, chapter_index, is_hidden) VALUES ('p', 'book', 'c.xhtml', 0, 0, 0, 'paragraph', 'Original paragraph', 0, 0)"
            )
            try db.execute(
                sql:
                    "INSERT INTO timeline_item (id, audiobook_id, item_type, title, audio_start_time, audio_end_time, epub_block_id) VALUES ('t', 'book', 'textSegment', 'Paragraph', 0, 5, 'p')"
            )
        }
        let model = ReaderFeedViewModel(audiobookID: "book", db: database.writer)
        model.reloadOffMain()
        model.searchQuery = "Original"
        await model.waitForReload()
        model.updateActiveBlock(time: 2, currentTrackChapterIndices: nil)
        #expect(model.activeBlockID == "p")
        #expect(model.displaySections.flatMap(\.items).map(\.id) == ["b-p"])
    }

    @Test func asyncSearchPreservesLiteralWildcardsHiddenPolicyAndCancellation() async throws {
        let database = try DatabaseService(inMemory: ())
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('search', 'Search', 60)")
            for (index, text, hidden) in [
                (0, "100% match", false), (1, "1000 match", false), (2, "100% hidden", true),
            ] {
                try db.execute(
                    sql:
                        "INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, text, is_hidden) VALUES (?, 'search', 'c.xhtml', 0, ?, ?, 'paragraph', ?, ?)",
                    arguments: ["p\(index)", index, index, text, hidden])
            }
        }
        let dao = EPubBlockDAO(db: database.writer)
        let rows = try await dao.searchBlocksAsync(for: "search", query: "%")
        #expect(rows.map(\.id) == ["p0"])
        #expect(try dao.searchBlocks(for: "search", query: "%").map(\.id) == rows.map(\.id))
        let task = Task { try await dao.searchBlocksAsync(for: "search", query: "%") }
        task.cancel()
        do {
            _ = try await task.value; Issue.record("Cancelled search returned rows")
        } catch is CancellationError {}
    }

    @Test func backgroundWidgetMergeRetainsFailedPendingEdits() async throws {
        let database = try DatabaseService(inMemory: ())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audit-pending-\(UUID())")
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        for url in [a, b] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try AudiobookDAO(db: database.writer).insert(
                AudiobookRecord(
                    id: url.absoluteString, title: url.lastPathComponent, duration: 0,
                    addedAt: "2026-10-22T00:00:00Z"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlayerModel()
        model.databaseService = database
        model.openLibraryBook(LibraryOpenTarget(url: a, scopedRoot: nil))
        let pending = Bookmark(title: "Pending edit", folderKey: a.absoluteString, timestamp: 1)
        try database.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER fail_bookmark_insert BEFORE INSERT ON bookmark BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
            )
        }
        model.bookmarkStore.bookmarks = [pending]
        model.bookmarkStore.onPersist?([pending])
        await model.bookmarkStore.flushPersistence()
        try database.write { db in try db.execute(sql: "DROP TRIGGER fail_bookmark_insert") }
        model.openLibraryBook(LibraryOpenTarget(url: b, scopedRoot: nil))
        let incoming = Bookmark(title: "Widget capture", folderKey: a.absoluteString, timestamp: 2)
        let suite = "audit-pending-widget-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([incoming]), forKey: "bookmarks_" + a.absoluteString)
        for task in model.drainPendingWidgetBookmarks(from: defaults) { await task.value }
        model.openLibraryBook(LibraryOpenTarget(url: a, scopedRoot: nil))
        #expect(Set(model.bookmarkStore.bookmarks.map(\.id)) == [pending.id, incoming.id])
        #expect(try BookmarkDAO(db: database.writer).bookmarks(for: a.absoluteString).count == 2)
    }

    @Test func scannedDurationIncludesEveryAudioFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audit-tracks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var urls: [URL] = []
        for seconds in [2, 3] {
            let url = root.appendingPathComponent("\(seconds).wav")
            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData)[0]
            for i in 0..<Int(buffer.frameLength) { samples[i] = 0 }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings);
                try file.write(from: buffer)
            }
            urls.append(url)
        }
        let result = await LibraryScanner.readMetadata(
            for: DiscoveredBook(folderURL: root, audioFiles: urls, companionEPUB: nil))
        #expect(abs(result.duration - 5) < 0.01)
        let missing = root.appendingPathComponent("missing")
        #expect(!LibraryScanner.discover(in: missing).isComplete)
    }

    @Test func incompleteAndCancelledScansPreserveAvailabilityAndScanStamp() async throws {
        let database = try DatabaseService(inMemory: ())
        let service = LibraryService(db: database)
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audit-scan-\(UUID())")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let root = try service.registerRoot(url: rootURL)
        let book = AudiobookRecord(
            id: rootURL.appendingPathComponent("book").absoluteString, title: "Kept", duration: 120,
            addedAt: "2026-10-22T00:00:00Z", sourceRootID: root.id)
        try AudiobookDAO(db: database.writer).insert(book)
        let result = try await service.rescan(
            root: root,
            discover: { _ in .init(books: [], isComplete: false) },
            readMetadata: { _ in .init(title: "Unused", duration: 0) }, coversDir: rootURL)
        #expect(result.hidden == 0)
        #expect(try AudiobookDAO(db: database.writer).get(book.id)?.isAvailable == true)
        #expect(
            try LibraryRootDAO(db: database.writer).get(root.id)?.lastScannedAt
                == root.lastScannedAt)
        let task = Task { @MainActor in
            try await service.rescan(
                root: root,
                discover: { _ in .init(books: [], isComplete: true) },
                readMetadata: { _ in .init(title: "Unused", duration: 0) }, coversDir: rootURL)
        }
        task.cancel()
        do {
            _ = try await task.value; Issue.record("Cancelled scan committed")
        } catch is CancellationError {}
        #expect(try AudiobookDAO(db: database.writer).get(book.id)?.isAvailable == true)
    }

    @Test func hiddenTextPreventsReplacementImport() async throws {
        let database = try DatabaseService(inMemory: ())
        let audio = AudiobookRecord(
            id: "file:///synthetic-audio/", title: "Audio", duration: 60,
            addedAt: "2026-10-22T00:00:00Z")
        try AudiobookDAO(db: database.writer).insert(audio)
        try database.write { db in
            try db.execute(
                sql:
                    "INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, text, is_hidden) VALUES ('hidden', ?, 'c.xhtml', 0, 0, 0, 'paragraph', 'Kept', 1)",
                arguments: [audio.id])
        }
        let service = ReadAlongMergeService(db: database)
        #expect(service.hasReadAlongText(audio.id))
        let text = AudiobookRecord(
            id: "file:///missing-text/", title: "Text", duration: 0, addedAt: "2026-10-22T00:00:00Z"
        )
        await #expect(throws: ReadAlongMergeService.MergeError.self) {
            try await service.merge(
                text: text, intoAudio: audio, libraryService: LibraryService(db: database))
        }
        #expect(try EPubBlockDAO(db: database.writer).count(for: audio.id) == 1)
    }

    @Test func readerThumbnailIsBoundedAndFailedPathsCanRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audit-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = ReaderImageLoader()
        #expect(await loader.image(storedPath: url.path, maxPixelSize: 32) == nil)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 12)).image {
            context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 12))
        }
        try #require(image.pngData()).write(to: url)
        let decoded = try #require(await loader.image(storedPath: url.path, maxPixelSize: 32))
        #expect(max(decoded.width, decoded.height) <= 32)
    }

    @Test func bookmarkRestorePrefersSQLAndDoesNotResurrectDeletedLegacyRows() async throws {
        let database = try DatabaseService(inMemory: ())
        try database.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration) VALUES ('A', 'A', 60), ('B', 'B', 60)"
            )
        }
        let suite = "audit-bookmarks-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = Persistence(defaults: defaults)
        let legacy = Bookmark(title: "Legacy recovery", folderKey: "A", timestamp: 1)
        let current = Bookmark(title: "SQL edit", folderKey: "A", timestamp: 2)
        persistence.saveBookmarks([legacy], for: "A")
        try BookmarkStore.replaceBookmarks([current], for: "A", database: database)
        let store = BookmarkStore()
        var key = "A"
        store.storageKeyProvider = { key }
        store.configureSQLPersistence(database: database)
        try store.restore(database: database, persistence: persistence, key: key, folderURL: nil)
        #expect(store.bookmarks.map(\.id) == [current.id])
        store.bookmarks = []
        store.onPersist?([])
        key = "B"
        try store.restore(database: database, persistence: persistence, key: key, folderURL: nil)
        #expect(store.bookmarks.isEmpty)
        key = "A"
        try store.restore(database: database, persistence: persistence, key: key, folderURL: nil)
        #expect(store.bookmarks.isEmpty)
        await store.flushPersistence()
        let reopened = BookmarkStore()
        try reopened.restore(database: database, persistence: persistence, key: key, folderURL: nil)
        #expect(reopened.bookmarks.isEmpty)
        #expect(persistence.loadBookmarks(for: "A").map(\.id) == [legacy.id])
    }

    @Test func legacyRestoreBindsNilAndOldFolderKeysToSelectedBook() throws {
        let database = try DatabaseService(inMemory: ())
        try AudiobookDAO(db: database.writer).insert(
            AudiobookRecord(
                id: "selected", title: "Selected", duration: 60, addedAt: "2026-10-22T00:00:00Z"))
        let suite = "audit-legacy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = Persistence(defaults: defaults)
        let legacy = [
            Bookmark(title: "No key", timestamp: 1),
            Bookmark(title: "Old folder", folderKey: "old-parent", timestamp: 2),
        ]
        persistence.saveBookmarks(legacy, for: "selected")
        let store = BookmarkStore()
        try store.restore(
            database: database, persistence: persistence, key: "selected", folderURL: nil)
        #expect(store.bookmarks.map(\.folderKey) == ["selected", "selected"])
        #expect(try BookmarkDAO(db: database.writer).bookmarks(for: "selected").count == 2)
        let reopened = BookmarkStore()
        try reopened.restore(
            database: database, persistence: persistence, key: "selected", folderURL: nil)
        #expect(reopened.bookmarks.map(\.id) == legacy.map(\.id))
    }

    @Test func legacyIDCollisionPreservesParentAndRecoveredFileCopy() throws {
        let database = try DatabaseService(inMemory: ())
        for key in ["parent", "file"] {
            try AudiobookDAO(db: database.writer).insert(
                AudiobookRecord(id: key, title: key, duration: 60, addedAt: "2026-10-22T00:00:00Z"))
        }
        let original = Bookmark(
            title: "Keep both scopes", folderKey: "parent", timestamp: 2, note: "Recovery note")
        try BookmarkStore.replaceBookmarks([original], for: "parent", database: database)
        let suite = "audit-collision-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = Persistence(defaults: defaults)
        persistence.saveBookmarks([original], for: "file")
        let store = BookmarkStore()
        try store.restore(database: database, persistence: persistence, key: "file", folderURL: nil)
        #expect(store.bookmarks.count == 1)
        #expect(store.bookmarks.first?.note == original.note)
        #expect(store.bookmarks.first?.id != original.id)
        let reopened = BookmarkStore()
        try reopened.restore(
            database: database, persistence: persistence, key: "file", folderURL: nil)
        #expect(reopened.bookmarks == store.bookmarks)
        #expect(
            try BookmarkDAO(db: database.writer).bookmarks(for: "parent").map(\.id) == [
                original.id.uuidString
            ])
    }

    @Test func failedNoteSaveReportsFailure() throws {
        let database = try DatabaseService(inMemory: ())
        let model = ReaderFeedViewModel(audiobookID: "missing", db: database.writer)
        #expect(!model.addNote(text: "Retain this draft", atBlockID: "missing"))
        #expect(
            !model.addVoiceMemo(
                fileURL: URL(fileURLWithPath: "/tmp/recover.m4a"), duration: 3, atBlockID: "missing"
            ))
    }

    @Test func failedRestoreCannotReplaceUnreadableSQLBookmarks() async throws {
        let database = try DatabaseService(inMemory: ())
        try AudiobookDAO(db: database.writer).insert(
            AudiobookRecord(
                id: "book", title: "Kept", duration: 60, addedAt: "2026-10-22T00:00:00Z"))
        let original = Bookmark(title: "Recoverable row", folderKey: "book", timestamp: 2)
        try BookmarkStore.replaceBookmarks([original], for: "book", database: database)
        try database.write { db in
            try db.execute(
                sql: "ALTER TABLE bookmark RENAME TO audit_bookmark_recovery")
        }
        let store = BookmarkStore()
        store.storageKeyProvider = { "book" }
        store.configureSQLPersistence(database: database)
        #expect(throws: (any Error).self) {
            try store.restore(
                database: database, persistence: Persistence(), key: "book", folderURL: nil)
        }
        try database.write { db in
            try db.execute(sql: "ALTER TABLE audit_bookmark_recovery RENAME TO bookmark")
        }
        store.onPersist?([])
        await store.flushPersistence()
        let ids = try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM bookmark WHERE audiobook_id = 'book'")
        }
        #expect(ids == [original.id.uuidString])
    }

    @Test func timelineIndexPreservesScopeAndOverlapOrder() {
        let rows: [ReaderActiveBlockResolver.TimelineRow] = [
            (0, 12, "front", nil, nil), (0, 10, "other", 2, "2-0"),
            (1, 8, "first", 1, "1-0"), (2, 9, "overlap", 1, "1-0"),
        ]
        let index = ReaderActiveBlockResolver.TimelineIndex(rows: rows)
        for scope: Set<Int> in [[0], [1], [2], [0, 1], [1, 2], []] {
            for time in [0.0, 1, 3, 8, 10, 12] {
                #expect(
                    ReaderActiveBlockResolver.activeBlockID(
                        in: index, time: time, currentTrackChapterIndices: scope)
                        == ReaderActiveBlockResolver.activeBlockID(
                            in: rows, time: time, currentTrackChapterIndices: scope))
            }
        }
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: index, time: 3, currentTrackSegmentKey: "1-0", currentTrackChapterIndices: [2])
                == "first")
    }

    @Test func silenceRequiresEveryChannelToBeQuiet() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audit-stereo-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000))
        buffer.frameLength = 64_000
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<64_000 { channels[0][i] = 0; channels[1][i] = 0.25 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings);
            try file.write(from: buffer)
        }
        let gaps = try await SilenceDetectionService(audioURL: url).detectSilences()
        #expect(gaps.isEmpty)
    }
}
