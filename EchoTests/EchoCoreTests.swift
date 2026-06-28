// SPDX-License-Identifier: GPL-3.0-or-later
//
//  EchoCoreTests.swift
//  EchoCoreTests
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct EchoCoreTests {

    /// Creates an in-memory database with the current baseline schema applied.
    private func makeTestDB() throws -> DatabaseWriter {
        try DatabaseService(inMemory: ()).writer
    }

    @Test func playerDeepLinkParsesPlayURLWithoutTime() throws {
        let link = try #require(PlayerDeepLink(url: URL(string: "echoaudio://play")!))

        #expect(link.action == .play(time: nil))
    }

    @Test func playerDeepLinkParsesPlayURLWithTime() throws {
        let link = try #require(PlayerDeepLink(url: URL(string: "echoaudio://play?time=30")!))

        #expect(link.action == .play(time: 30))
    }

    @Test func playerDeepLinkParsesCustomProductPageURLs() throws {
        let focusLink = try #require(PlayerDeepLink(url: URL(string: "echoaudio://focus")!))
        #expect(focusLink.action == .focus)

        let readLink = try #require(PlayerDeepLink(url: URL(string: "echoaudio://read")!))
        #expect(readLink.action == .read)

        let studyLink = try #require(PlayerDeepLink(url: URL(string: "echoaudio://study")!))
        #expect(studyLink.action == .study)
    }

    @Test func playerDeepLinkRejectsUnregisteredScheme() {
        // The pre-rebrand scheme must no longer parse.
        #expect(PlayerDeepLink(url: URL(string: "orbitaudio://play?time=30")!) == nil)
    }

    @Test func deepLinkHandlerHandlesCustomProductPageActions() throws {
        var handler = DeepLinkHandler()

        let focusLink = try #require(PlayerDeepLink(url: URL(string: "echoaudio://focus")!))
        let focusAction = handler.handle(focusLink, isItemLoaded: false, isPlaying: false)
        #expect(focusAction == .showFocusGuide)

        let readLink = try #require(PlayerDeepLink(url: URL(string: "echoaudio://read")!))
        let readAction = handler.handle(readLink, isItemLoaded: false, isPlaying: false)
        #expect(readAction == .navigate(.read))

        let studyLink = try #require(PlayerDeepLink(url: URL(string: "echoaudio://study")!))
        let studyAction = handler.handle(studyLink, isItemLoaded: false, isPlaying: false)
        #expect(studyAction == .navigate(.read))
    }

    @Test func bookmarkMarkdownUsesCanonicalDeepLinkScheme() {
        let bookmarks = [
            Bookmark(title: "Note", timestamp: 42.5, note: "Interesting", voiceMemoFileName: nil)
        ]

        let markdown = Bookmark.markdownExport(for: bookmarks)

        #expect(markdown.contains("[Play in App](echoaudio://play?time=42.5)"))
        #expect(!markdown.contains("orbitaudio"))
    }

    @Test func bookmarkSidecarURLUsesFolderNameForDirectoryBooks() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sidecar = Bookmark.sidecarURL(for: folder)

        #expect(sidecar == folder.appendingPathComponent("\(folder.lastPathComponent).json"))
    }

    @Test func bookmarkSidecarURLUsesAudioBasenameForSingleFileBooks() {
        let file = URL(fileURLWithPath: "/tmp/Example Book.m4b")

        let sidecar = Bookmark.sidecarURL(for: file)

        #expect(sidecar.path == "/tmp/Example Book.json")
    }

    @Test func bookmarkDecodingTreatsImageFileNameAsOptionalForLegacyJSON() throws {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "title": "Legacy",
              "timestamp": 12.5,
              "isEnabled": true
            }
            """

        let bookmark = try JSONDecoder().decode(Bookmark.self, from: Data(json.utf8))

        #expect(bookmark.bookmarkImageFileName == nil)
    }

    @Test func bookmarkImageURLPrefersAudiobookDirectory() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageURL = folder.appendingPathComponent("bookmark-image.jpg")
        try Data("image".utf8).write(to: imageURL)

        let bookmark = Bookmark(timestamp: 10, bookmarkImageFileName: "bookmark-image.jpg")

        #expect(bookmark.bookmarkImageURL(in: folder) == imageURL)
    }

    @Test func activeArtworkBookmarkUsesMostRecentEnabledImageBookmarkAtOrBeforePlaybackTime() {
        let trackId = "track-a"
        let bookmarks = [
            Bookmark(
                title: "Early", trackId: trackId, timestamp: 5, bookmarkImageFileName: "early.jpg"),
            Bookmark(
                title: "Later", trackId: trackId, timestamp: 12, bookmarkImageFileName: "later.jpg"),
            Bookmark(
                title: "Future", trackId: trackId, timestamp: 30,
                bookmarkImageFileName: "future.jpg"),
            Bookmark(
                title: "Other Track", trackId: "track-b", timestamp: 20,
                bookmarkImageFileName: "other.jpg"),
            Bookmark(title: "No Image", trackId: trackId, timestamp: 22),
        ]

        let active = BookmarkStore.activeArtworkBookmark(from: bookmarks, at: 24, trackId: trackId)

        #expect(active?.title == "Later")
    }

    @Test func bookmarkStoreClearLocationContextDropsVisiblePlaceDataAndPersists() throws {
        let store = BookmarkStore()
        let locatedID = UUID()
        var persistedBookmarks: [Bookmark] = []
        var changeCount = 0
        store.onPersist = { persistedBookmarks = $0 }
        store.onBookmarksChanged = { changeCount += 1 }

        store.bookmarks = [
            Bookmark(
                id: locatedID, title: "Located", timestamp: 12,
                latitude: 44.65, longitude: -63.57, placeName: "Halifax"),
            Bookmark(title: "Plain", timestamp: 24),
        ]

        let clearedCount = store.clearLocationContext()

        #expect(clearedCount == 1)
        #expect(changeCount == 1)
        #expect(store.bookmarks.count == 2)
        let locatedBookmark = try #require(store.bookmarks.first { $0.id == locatedID })
        #expect(locatedBookmark.latitude == nil)
        #expect(locatedBookmark.longitude == nil)
        #expect(locatedBookmark.placeName == nil)
        #expect(persistedBookmarks == store.bookmarks)
    }

    @Test func settingsRegisterLexendAsDefaultFont() {
        let suiteName = "settings-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: defaults)

        #expect(defaults.string(forKey: "appFont") == "Lexend")
    }

    @Test func settingsPersistsWatchBackgroundStyle() {
        let suiteName = "watch-background-style-\(UUID().uuidString)"
        let appGroupName = "watch-background-style-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(settings.watchBackgroundStyle == "artwork")

        settings.watchBackgroundStyle = "black"

        #expect(appGroupDefaults.string(forKey: "watchBackgroundStyle") == "black")
    }

    @Test func settingsUsesClassicWatchFaceAndProgressDefaults() {
        let suiteName = "watch-progress-defaults-\(UUID().uuidString)"
        let appGroupName = "watch-progress-defaults-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: appGroupDefaults)
        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(SettingsManager.Defaults.watchArtworkLayout == "classic")
        #expect(SettingsManager.Defaults.linearBarMode == "chapter")
        #expect(SettingsManager.Defaults.circularRingMode == "total")
        #expect(appGroupDefaults.string(forKey: "watchArtworkLayout") == "classic")
        #expect(appGroupDefaults.string(forKey: "linearBarMode") == "chapter")
        #expect(appGroupDefaults.string(forKey: "circularRingMode") == "total")
        #expect(settings.watchArtworkLayout == "classic")
        #expect(settings.linearBarMode == "chapter")
        #expect(settings.circularRingMode == "total")
    }

    @Test func settingsPreservesPersistedWatchFaceAndProgressChoices() {
        let suiteName = "watch-progress-persisted-\(UUID().uuidString)"
        let appGroupName = "watch-progress-persisted-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        appGroupDefaults.set("immersive", forKey: "watchArtworkLayout")
        appGroupDefaults.set("total", forKey: "linearBarMode")
        appGroupDefaults.set("chapter", forKey: "circularRingMode")

        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(settings.watchArtworkLayout == "immersive")
        #expect(settings.linearBarMode == "total")
        #expect(settings.circularRingMode == "chapter")
    }

    @Test func settingsPersistsSeekDurationsAndLayoutCustomizations() {
        let suiteName = "seek-durations-\(UUID().uuidString)"
        let appGroupName = "seek-durations-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        // Defaults
        #expect(settings.seekBackwardDuration == 30)
        #expect(settings.seekForwardDuration == 30)
        #expect(settings.phonePage == [.skipBackward, .empty, .playPause, .empty, .skipForward])
        #expect(settings.phonePresets.isEmpty)
        #expect(settings.watchPresets.isEmpty)

        // Modify settings
        settings.seekBackwardDuration = 45
        settings.seekForwardDuration = 15
        settings.phonePage = [.empty, .skipBackward, .playPause, .skipForward, .empty]

        let phonePreset = PhonePreset(
            name: "Test Phone Preset",
            slots: [.empty, .skipBackward, .playPause, .skipForward, .empty])
        settings.phonePresets = [phonePreset]

        let watchPreset = WatchPreset(
            name: "Test Watch Preset",
            page1: [.empty, .skipBackward, .playPause, .skipForward, .empty], page2: [])
        settings.watchPresets = [watchPreset]

        // Verify values are persisted
        #expect(settings.seekBackwardDuration == 45)
        #expect(settings.seekForwardDuration == 15)
        #expect(settings.phonePage == [.empty, .skipBackward, .playPause, .skipForward, .empty])
        #expect(settings.phonePresets.count == 1)
        #expect(settings.phonePresets.first?.name == "Test Phone Preset")
        #expect(settings.watchPresets.count == 1)
        #expect(settings.watchPresets.first?.name == "Test Watch Preset")
    }

    @Test func settingsPersistsStudyGlobalNewChapterLimit() {
        let suiteName = "study-global-new-chapter-limit-\(UUID().uuidString)"
        let appGroupName = "study-global-new-chapter-limit-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(settings.studyGlobalNewChapterLimit == SettingsManager.Defaults.studyGlobalNewChapterLimit)

        settings.studyGlobalNewChapterLimit = 4
        #expect(defaults.integer(forKey: "studyGlobalNewChapterLimit") == 4)

        settings.studyGlobalNewChapterLimit = 0
        #expect(settings.studyGlobalNewChapterLimit == 1)
        #expect(defaults.integer(forKey: "studyGlobalNewChapterLimit") == 1)

        settings.studyGlobalNewChapterLimit = 99
        #expect(settings.studyGlobalNewChapterLimit == SettingsManager.Defaults.studyGlobalNewChapterLimit)
        #expect(defaults.integer(forKey: "studyGlobalNewChapterLimit") == SettingsManager.Defaults.studyGlobalNewChapterLimit)
    }

    @Test func settingsPersistsAndReloadsReaderDefaults() {
        let suiteName = "reader-defaults-\(UUID().uuidString)"
        let appGroupName = "reader-defaults-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        defaults.set(0.0, forKey: "readerFontSize")
        defaults.set(0.0, forKey: "readerLineSpacing")

        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(settings.readerFontSize == SettingsManager.Defaults.readerFontSize)
        #expect(settings.readerLineSpacing == SettingsManager.Defaults.readerLineSpacing)
        #expect(settings.readerCardTint == SettingsManager.Defaults.readerCardTint)

        settings.readerFontSize = 21
        settings.readerLineSpacing = 1.8
        settings.readerCardTint = "#E3F2FD"

        #expect(defaults.double(forKey: "readerFontSize") == 21)
        #expect(defaults.double(forKey: "readerLineSpacing") == 1.8)
        #expect(defaults.string(forKey: "readerCardTint") == "#E3F2FD")

        let reloaded = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(reloaded.readerFontSize == 21)
        #expect(reloaded.readerLineSpacing == 1.8)
        #expect(reloaded.readerCardTint == "#E3F2FD")
    }

    @Test func settingsReaderDefaultsUseObservedStoredProperties() throws {
        let source = try Self.source(pathComponents: "EchoCore", "Services", "SettingsManager.swift")

        #expect(source.contains("var readerFontSize: Double {"))
        #expect(source.contains("didSet { defaults.set(readerFontSize, forKey: Keys.readerFontSize) }"))
        #expect(!source.contains("get { defaults.double(forKey: Keys.readerFontSize)"))
        #expect(!source.contains("get { defaults.string(forKey: Keys.readerCardTint)"))
    }

    @Test func settingsNormalizeLegacyHelveticaToSystemFont() {
        #expect(SettingsManager.normalizedAppFont("Helvetica") == SettingsManager.systemFontName)
    }

    // MARK: - Database Tests

    @Test func databaseBaselineSchemaCreatesAllTables() throws {
        let db = try DatabaseService(inMemory: ())
        let tables = try db.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type='table' OR type='view'
                    ORDER BY name
                    """)
        }
        #expect(tables.contains("audiobook"))
        #expect(tables.contains("track"))
        #expect(tables.contains("chapter"))
        #expect(tables.contains("bookmark"))
        #expect(tables.contains("flashcard"))
        #expect(tables.contains("transcription_segment"))
        #expect(tables.contains("transcription_word"))
        #expect(tables.contains("playback_event"))
        #expect(tables.contains("playback_state"))
        #expect(tables.contains("settings"))
        #expect(tables.contains("timeline"))
    }

    @Test func databaseBookmarkDAOInsertAndRead() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BookmarkDAO(db: db.writer)
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let bm = BookmarkRecord(
            id: UUID().uuidString,
            audiobookID: "book-1",
            trackID: nil,
            title: "Test",
            mediaTimestamp: 30.0,
            note: nil,
            voiceMemoPath: nil,
            imagePath: nil,
            isEnabled: true,
            playlistPosition: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modifiedAt: ISO8601DateFormatter().string(from: Date())
        )
        try dao.insert(bm)
        let results = try dao.bookmarks(for: "book-1")
        #expect(results.count == 1)
        #expect(results.first?.title == "Test")
        #expect(results.first?.mediaTimestamp == 30.0)
    }

    @Test func databaseBookmarkDAODelete() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BookmarkDAO(db: db.writer)
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let id = UUID().uuidString
        let bm = BookmarkRecord(
            id: id, audiobookID: "book-1", trackID: nil,
            title: "Delete Me", mediaTimestamp: 0,
            note: nil, voiceMemoPath: nil, imagePath: nil,
            isEnabled: true, playlistPosition: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modifiedAt: ISO8601DateFormatter().string(from: Date())
        )
        try dao.insert(bm)
        try dao.delete(id: id)
        let results = try dao.bookmarks(for: "book-1")
        #expect(results.isEmpty)
    }

    @Test func databaseTimelineViewUnionsAllTypes() throws {
        let queue = try makeTestDB()

        let items: [TimelineItem] = [
            TimelineItem(
                id: "t1", audiobookID: "book-1", itemType: .chapterMarker, title: "Track 1",
                audioStartTime: 0, granularityLevel: .chapter, isEnabled: true),
            TimelineItem(
                id: "ch1", audiobookID: "book-1", itemType: .chapterMarker, title: "Chapter 1",
                audioStartTime: 0, audioEndTime: 1800, granularityLevel: .chapter, isEnabled: true),
            TimelineItem(
                id: "bm1", audiobookID: "book-1", itemType: .bookmark, title: "Bookmark 1",
                audioStartTime: 120, granularityLevel: .sentence, isEnabled: true),
            TimelineItem(
                id: "fc1", audiobookID: "book-1", itemType: .ankiCard, title: "Question?",
                subtitle: "Answer.", audioStartTime: 300, granularityLevel: .sentence,
                isEnabled: true),
            TimelineItem(
                id: "ts1", audiobookID: "book-1", itemType: .textSegment, title: "Hello world",
                audioStartTime: 0, audioEndTime: 5, granularityLevel: .sentence, isEnabled: true),
        ]

        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            for var item in items { try item.insert(db) }
        }

        let fetched = try queue.read { db in
            try TimelineItem.filter(Column("audiobook_id") == "book-1").fetchAll(db)
        }
        #expect(fetched.count == 5)
        #expect(fetched.contains(where: { $0.itemType == .chapterMarker }))
        #expect(fetched.contains(where: { $0.itemType == .bookmark }))
        #expect(fetched.contains(where: { $0.itemType == .ankiCard }))
        #expect(fetched.contains(where: { $0.itemType == .textSegment }))
    }

    @Test func databaseTimelineFilterByType() throws {
        let queue = try makeTestDB()

        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            let items: [TimelineItem] = [
                TimelineItem(
                    id: "bm1", audiobookID: "book-1", itemType: .bookmark, title: "BM",
                    audioStartTime: 10, granularityLevel: .sentence, isEnabled: true),
                TimelineItem(
                    id: "fc1", audiobookID: "book-1", itemType: .ankiCard, title: "Q",
                    subtitle: "A", audioStartTime: 20, granularityLevel: .sentence, isEnabled: true),
            ]
            for var item in items { try item.insert(db) }
        }

        let timelines = TimelineDAO(db: queue)
        let bookmarks = try timelines.items(for: "book-1", types: [.bookmark])
        #expect(bookmarks.count == 1)
        #expect(bookmarks.first?.itemType == .bookmark)

        let cards = try timelines.items(for: "book-1", types: [.ankiCard])
        #expect(cards.count == 1)
        #expect(cards.first?.itemType == .ankiCard)
    }

    @Test func databaseTimelineFilterByTimeRange() throws {
        let queue = try makeTestDB()

        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            let items: [TimelineItem] = [
                TimelineItem(
                    id: "bm1", audiobookID: "book-1", itemType: .bookmark, title: "Early",
                    audioStartTime: 10, granularityLevel: .sentence, isEnabled: true),
                TimelineItem(
                    id: "bm2", audiobookID: "book-1", itemType: .bookmark, title: "Mid",
                    audioStartTime: 100, granularityLevel: .sentence, isEnabled: true),
                TimelineItem(
                    id: "bm3", audiobookID: "book-1", itemType: .bookmark, title: "Late",
                    audioStartTime: 200, granularityLevel: .sentence, isEnabled: true),
            ]
            for var item in items { try item.insert(db) }
        }

        let timelineDAO = TimelineDAO(db: queue)
        let mid = try timelineDAO.items(in: 50...150, audiobookID: "book-1")
        // Items at 10s and 100s both fall into 50-150 range (nil end times overlap)
        #expect(mid.count == 2)
    }

    private static func source(pathComponents: String...) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = pathComponents.reduce(directory.deletingLastPathComponent()) {
                partialResult, pathComponent in
                partialResult.appendingPathComponent(pathComponent)
            }

            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

}
