// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct ExportSourceResolverTests {
    private func seedTrack(_ db: DatabaseService, narrationVoice: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk', 'Book', 60)")
        }
        let track = TrackRecord(
            id: "t0", audiobookID: "bk", title: "Chapter 1", duration: 10,
            filePath: "file:///x.m4a", isEnabled: true, sortOrder: 0,
            playlistPosition: nil, narrationVoice: narrationVoice)
        try TrackDAO(db: db.writer).insertAll([track], audiobookID: "bk")
    }

    @Test func detectsNarratedWhenAnyTrackHasVoice() throws {
        let db = try DatabaseService(inMemory: ())
        try seedTrack(db, narrationVoice: "af_heart")
        #expect(ExportSourceResolver.isNarrated(audiobookID: "bk", databaseWriter: db.writer))
        let source = ExportSourceResolver.resolve(
            audiobookID: "bk", databaseWriter: db.writer,
            cacheDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(source is NarrationCacheSource)
    }

    @Test func detectsImportedWhenNoVoice() throws {
        let db = try DatabaseService(inMemory: ())
        try seedTrack(db, narrationVoice: nil)
        #expect(!ExportSourceResolver.isNarrated(audiobookID: "bk", databaseWriter: db.writer))
        let source = ExportSourceResolver.resolve(
            audiobookID: "bk", databaseWriter: db.writer,
            cacheDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(source is ImportedBookSource)
    }
}
