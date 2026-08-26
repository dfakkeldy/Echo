// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct TimelineIngestionTrackRefreshTests {

    @Test func reingestUpdatesTracksReferencedByBookmarksAndPlaybackEvents() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/track-refresh-\(UUID().uuidString)")
        let audiobookID = folder.absoluteString
        let firstTrackURL = folder.appendingPathComponent("01-intro.m4b")
        let secondTrackURL = folder.appendingPathComponent("02-body.m4b")

        TimelineIngestionService.persistAudiobook(
            db: db,
            folderURL: folder,
            tracks: [
                Track(url: firstTrackURL, title: "Intro"),
                Track(url: secondTrackURL, title: "Body")
            ],
            duration: 120
        )

        let bookmarkID = UUID().uuidString
        try BookmarkDAO(db: db.writer).insert(
            BookmarkRecord(
                id: bookmarkID,
                audiobookID: audiobookID,
                trackID: firstTrackURL.absoluteString,
                title: "Opening note",
                mediaTimestamp: 12,
                note: "Keep this reference",
                voiceMemoPath: nil,
                imagePath: nil,
                isEnabled: true,
                playlistPosition: nil,
                pdfViewStateJSON: nil,
                latitude: nil,
                longitude: nil,
                placeName: nil,
                createdAt: "2026-06-26T00:00:00Z",
                modifiedAt: "2026-06-26T00:00:00Z"
            ))
        try PlaybackEventDAO(db: db.writer).log(
            audiobookID: audiobookID,
            trackID: firstTrackURL.absoluteString,
            startedAt: Date(timeIntervalSince1970: 1_719_360_000),
            endedAt: Date(timeIntervalSince1970: 1_719_360_030),
            startPosition: 0,
            endPosition: 30,
            speed: 1.0,
            eventType: "play",
            source: "test"
        )

        TimelineIngestionService.persistAudiobook(
            db: db,
            folderURL: folder,
            tracks: [
                Track(url: secondTrackURL, title: "Body, moved first"),
                Track(url: firstTrackURL, title: "Intro, retitled")
            ],
            duration: 180
        )

        let refreshedTracks = try TrackDAO(db: db.writer).tracks(for: audiobookID)
        #expect(refreshedTracks.count == 2)
        #expect(refreshedTracks.map(\.id) == [
            secondTrackURL.absoluteString,
            firstTrackURL.absoluteString
        ])
        #expect(refreshedTracks.map(\.title) == [
            "Body, moved first",
            "Intro, retitled"
        ])

        let bookmark = try #require(try BookmarkDAO(db: db.writer).bookmark(id: bookmarkID))
        #expect(bookmark.trackID == firstTrackURL.absoluteString)

        let playbackTrackID = try db.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT track_id FROM playback_event WHERE audiobook_id = ?",
                arguments: [audiobookID]
            )
        }
        #expect(playbackTrackID == firstTrackURL.absoluteString)

        let audiobook = try #require(try AudiobookDAO(db: db.writer).get(audiobookID))
        #expect(audiobook.duration == 180)
        #expect(audiobook.fileCount == 2)
    }

    @Test func reingestNullsDependentsBeforeDeletingObsoleteTracks() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/track-prune-\(UUID().uuidString)")
        let audiobookID = folder.absoluteString
        let keepTrackURL = folder.appendingPathComponent("01-keep.m4b")
        let obsoleteTrackURL = folder.appendingPathComponent("02-drop.m4b")

        TimelineIngestionService.persistAudiobook(
            db: db,
            folderURL: folder,
            tracks: [
                Track(url: keepTrackURL, title: "Keep"),
                Track(url: obsoleteTrackURL, title: "Drop")
            ],
            duration: 240
        )

        let bookmarkID = UUID().uuidString
        try BookmarkDAO(db: db.writer).insert(
            BookmarkRecord(
                id: bookmarkID,
                audiobookID: audiobookID,
                trackID: obsoleteTrackURL.absoluteString,
                title: "Obsolete track bookmark",
                mediaTimestamp: 42,
                note: nil,
                voiceMemoPath: nil,
                imagePath: nil,
                isEnabled: true,
                playlistPosition: nil,
                pdfViewStateJSON: nil,
                latitude: nil,
                longitude: nil,
                placeName: nil,
                createdAt: "2026-06-26T00:00:00Z",
                modifiedAt: "2026-06-26T00:00:00Z"
            ))
        try PlaybackEventDAO(db: db.writer).log(
            audiobookID: audiobookID,
            trackID: obsoleteTrackURL.absoluteString,
            startedAt: Date(timeIntervalSince1970: 1_719_360_100),
            endedAt: Date(timeIntervalSince1970: 1_719_360_140),
            startPosition: 40,
            endPosition: 80,
            speed: 1.0,
            eventType: "play",
            source: "test"
        )

        TimelineIngestionService.persistAudiobook(
            db: db,
            folderURL: folder,
            tracks: [Track(url: keepTrackURL, title: "Keep, refreshed")],
            duration: 300
        )

        let refreshedTracks = try TrackDAO(db: db.writer).tracks(for: audiobookID)
        #expect(refreshedTracks.map(\.id) == [keepTrackURL.absoluteString])
        #expect(refreshedTracks.map(\.title) == ["Keep, refreshed"])

        let bookmark = try #require(try BookmarkDAO(db: db.writer).bookmark(id: bookmarkID))
        #expect(bookmark.trackID == nil)

        let playbackTrackID = try db.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT track_id
                    FROM playback_event
                    WHERE audiobook_id = ?
                    """,
                arguments: [audiobookID]
            )
        }
        #expect(playbackTrackID == nil)

        let playbackCount = try db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM playback_event WHERE audiobook_id = ?",
                arguments: [audiobookID]
            )
        }
        #expect(playbackCount == 1)
    }
}
