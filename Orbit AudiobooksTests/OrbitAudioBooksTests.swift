//
//  OrbitAudioBooksTests.swift
//  OrbitAudioBooksTests
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import Testing
import Foundation
import GRDB
@testable import Orbit_Audiobooks

@MainActor
struct OrbitAudioBooksTests {

    @Test func playerDeepLinkParsesPlayURLWithoutTime() throws {
        let link = try #require(PlayerDeepLink(url: URL(string: "orbitaudio://play")!))

        #expect(link == .play(time: nil))
    }

    @Test func playerDeepLinkParsesPlayURLWithTime() throws {
        let link = try #require(PlayerDeepLink(url: URL(string: "orbitaudio://play?time=30")!))

        #expect(link == .play(time: 30))
    }

    @Test func playerDeepLinkRejectsUnregisteredScheme() {
        #expect(PlayerDeepLink(url: URL(string: "orbitaudiobooks://play?time=30")!) == nil)
    }

    @Test func bookmarkMarkdownUsesCanonicalDeepLinkScheme() {
        let bookmarks = [
            Bookmark(title: "Note", timestamp: 42.5, note: "Interesting", voiceMemoFileName: nil)
        ]

        let markdown = Bookmark.markdownExport(for: bookmarks)

        #expect(markdown.contains("[Play in App](orbitaudio://play?time=42.5)"))
        #expect(!markdown.contains("orbitaudiobooks://"))
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
            Bookmark(title: "Early", trackId: trackId, timestamp: 5, bookmarkImageFileName: "early.jpg"),
            Bookmark(title: "Later", trackId: trackId, timestamp: 12, bookmarkImageFileName: "later.jpg"),
            Bookmark(title: "Future", trackId: trackId, timestamp: 30, bookmarkImageFileName: "future.jpg"),
            Bookmark(title: "Other Track", trackId: "track-b", timestamp: 20, bookmarkImageFileName: "other.jpg"),
            Bookmark(title: "No Image", trackId: trackId, timestamp: 22)
        ]

        let active = PlayerModel.activeArtworkBookmark(from: bookmarks, at: 24, trackId: trackId)

        #expect(active?.title == "Later")
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

    @Test func settingsNormalizeLegacyHelveticaToSystemFont() {
        #expect(SettingsManager.normalizedAppFont("Helvetica") == SettingsManager.systemFontName)
    }

    // MARK: - Database Tests

    @Test func databaseV1SchemaCreatesAllTables() throws {
        let db = try DatabaseService(inMemory: ())
        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
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
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
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
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
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
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)

        let items: [TimelineItem] = [
            TimelineItem(id: "t1", audiobookID: "book-1", itemType: .chapterMarker, title: "Track 1",
                        audioStartTime: 0, granularityLevel: .chapter, isEnabled: true),
            TimelineItem(id: "ch1", audiobookID: "book-1", itemType: .chapterMarker, title: "Chapter 1",
                        audioStartTime: 0, audioEndTime: 1800, granularityLevel: .chapter, isEnabled: true),
            TimelineItem(id: "bm1", audiobookID: "book-1", itemType: .bookmark, title: "Bookmark 1",
                        audioStartTime: 120, granularityLevel: .sentence, isEnabled: true),
            TimelineItem(id: "fc1", audiobookID: "book-1", itemType: .ankiCard, title: "Question?",
                        subtitle: "Answer.", audioStartTime: 300, granularityLevel: .sentence, isEnabled: true),
            TimelineItem(id: "ts1", audiobookID: "book-1", itemType: .textSegment, title: "Hello world",
                        audioStartTime: 0, audioEndTime: 5, granularityLevel: .sentence, isEnabled: true),
        ]
        try timelineDAO.ingest(items)

        let fetched = try timelineDAO.items(for: "book-1")
        #expect(fetched.count == 5)
        #expect(fetched.contains(where: { $0.itemType == .chapterMarker }))
        #expect(fetched.contains(where: { $0.itemType == .bookmark }))
        #expect(fetched.contains(where: { $0.itemType == .ankiCard }))
        #expect(fetched.contains(where: { $0.itemType == .textSegment }))
    }

    @Test func databaseTimelineFilterByType() throws {
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)

        let items: [TimelineItem] = [
            TimelineItem(id: "bm1", audiobookID: "book-1", itemType: .bookmark, title: "BM",
                        audioStartTime: 10, granularityLevel: .sentence, isEnabled: true),
            TimelineItem(id: "fc1", audiobookID: "book-1", itemType: .ankiCard, title: "Q",
                        subtitle: "A", audioStartTime: 20, granularityLevel: .sentence, isEnabled: true),
        ]
        try timelineDAO.ingest(items)

        let bookmarks = try timelineDAO.items(for: "book-1", types: [.bookmark])
        #expect(bookmarks.count == 1)
        #expect(bookmarks.first?.itemType == .bookmark)

        let cards = try timelineDAO.items(for: "book-1", types: [.ankiCard])
        #expect(cards.count == 1)
        #expect(cards.first?.itemType == .ankiCard)
    }

    @Test func databaseTimelineFilterByTimeRange() throws {
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)

        let items: [TimelineItem] = [
            TimelineItem(id: "bm1", audiobookID: "book-1", itemType: .bookmark, title: "Early",
                        audioStartTime: 10, granularityLevel: .sentence, isEnabled: true),
            TimelineItem(id: "bm2", audiobookID: "book-1", itemType: .bookmark, title: "Mid",
                        audioStartTime: 100, granularityLevel: .sentence, isEnabled: true),
            TimelineItem(id: "bm3", audiobookID: "book-1", itemType: .bookmark, title: "Late",
                        audioStartTime: 200, granularityLevel: .sentence, isEnabled: true),
        ]
        try timelineDAO.ingest(items)

        let mid = try timelineDAO.items(in: 50...150, audiobookID: "book-1")
        #expect(mid.count == 1)
        #expect(mid.first?.title == "Mid")
    }

}
