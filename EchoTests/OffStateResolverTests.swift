// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct OffStateResolverTests {
    /// Seed two blocks in chapter 0 (a heading + a paragraph) for "book-1".
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            // D2 fix: `duration` is NOT NULL with no default in the baseline schema.
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Book One', 0)
                    """)
            // D1 fix: epub_block has no `block_type` or `level` columns; the column
            // is `block_kind`, and `spine_href/spine_index/block_index` are all NOT NULL.
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text,
                       chapter_index, is_hidden, created_at, modified_at)
                    VALUES
                      ('ch0-h', 'book-1', 'ch0.xhtml', 0, 0,
                       0, 'heading', 'Chapter One',
                       0, 0, '2026-06-22T00:00:00Z', '2026-06-22T00:00:00Z'),
                      ('ch0-p', 'book-1', 'ch0.xhtml', 0, 1,
                       1, 'paragraph', 'Body text',
                       0, 0, '2026-06-22T00:00:00Z', '2026-06-22T00:00:00Z')
                    """)
        }
        return db
    }

    /// Write a `.echoplaylist.json` with the given track-enabled states.
    private func writeManifest(_ folder: URL, tracks: [(file: String, enabled: Bool)]) {
        let manifest = EchoPlaylistManifest(
            version: 1, title: "Book One", author: nil,
            tracks: tracks.map {
                EchoPlaylistManifest.ManifestTrack(
                    file: $0.file, title: nil, duration: 60, enabled: $0.enabled)
            },
            // D4 fix: `lastTrackId: String?` has no `= nil` default; must be explicit.
            playbackState: EchoPlaylistManifest.ManifestPlaybackState(lastTrackId: nil),
            bookmarks: nil)
        PlaylistManifestService.write(manifest, to: folder)
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func freshChapterIsAllOn() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .allOn)
    }

    @Test func hidingEpubMakesItEpubOff() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        try resolver.setEpubOff(true, audiobookID: "book-1", chapterIndex: 0)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .epubOff)
    }

    @Test func disablingAllTracksMakesItAudioOff() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        try resolver.setAudioOff(true, trackFiles: ["c0.m4b"])
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .audioOff)
    }

    @Test func partialTrackDisableIsNotAudioOff() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("a.m4b", false), ("b.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["a.m4b", "b.m4b"])
        // Only ALL-tracks-off counts as audio off.
        #expect(state == .allOn)
    }

    @Test func setAllOffMakesItAllOffThenAllOnAgain() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        try resolver.setAllOff(
            true, audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(
            try resolver.resolve(
                audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"]) == .allOff)
        try resolver.setAllOff(
            false, audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(
            try resolver.resolve(
                audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"]) == .allOn)
    }

    @Test func noManifestTreatsAudioAsOn() throws {
        let db = try seed()
        let resolver = OffStateResolver(db: db.writer, folderURL: nil)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .allOn)
    }
}
