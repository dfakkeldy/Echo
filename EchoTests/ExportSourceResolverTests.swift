// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
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
            cacheDirectory: URL(fileURLWithPath: "/tmp"),
            preferredVoice: VoiceCatalog.default.id)
        #expect(source is NarrationCacheSource)
    }

    @Test func detectsImportedWhenNoVoice() throws {
        let db = try DatabaseService(inMemory: ())
        try seedTrack(db, narrationVoice: nil)
        #expect(!ExportSourceResolver.isNarrated(audiobookID: "bk", databaseWriter: db.writer))
        let source = ExportSourceResolver.resolve(
            audiobookID: "bk", databaseWriter: db.writer,
            cacheDirectory: URL(fileURLWithPath: "/tmp"),
            preferredVoice: VoiceCatalog.default.id)
        #expect(source is ImportedBookSource)
    }

    @Test func matchingZeroTrackAnthologyRoutesToNarrationAndFailsIncomplete() async throws {
        let db = try DatabaseService(inMemory: ())
        let audiobookID = try seedAnthologyReceipt(db, validDigest: true)
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "echo-resolver-zero-track-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let source = ExportSourceResolver.resolve(
            audiobookID: audiobookID, databaseWriter: db.writer,
            cacheDirectory: cacheDirectory, preferredVoice: VoiceCatalog.default.id)

        #expect(source is NarrationCacheSource)
        await #expect(
            throws: AnthologyNarrationReadinessError.incomplete(chapterDisplayNumbers: [1])
        ) {
            try await source.items()
        }
    }

    @Test func matchingInvalidReceiptRoutesToNarrationAndFailsInvalidPlan() async throws {
        let db = try DatabaseService(inMemory: ())
        let audiobookID = try seedAnthologyReceipt(db, validDigest: false)
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "echo-resolver-invalid-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let source = ExportSourceResolver.resolve(
            audiobookID: audiobookID, databaseWriter: db.writer,
            cacheDirectory: cacheDirectory, preferredVoice: VoiceCatalog.default.id)

        #expect(source is NarrationCacheSource)
        await #expect(throws: AnthologyNarrationReadinessError.invalidPlan) {
            try await source.items()
        }
    }

    private func seedAnthologyReceipt(
        _ database: DatabaseService,
        validDigest: Bool
    ) throws -> String {
        let audiobookID = "receipt-\(UUID().uuidString)"
        let anthologyID = UUID()
        let entryID = UUID()
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Anthology', 0)",
                arguments: [audiobookID])
        }
        try AnthologyDAO(db: database.writer).save(
            AnthologyRecord(
                id: anthologyID.uuidString, title: "Anthology", subtitle: nil,
                creator: nil, coverPath: nil, nextStableSlot: 1, latestBuildRevision: 1,
                createdAt: "2026-08-02T12:00:00Z", modifiedAt: "2026-08-02T12:00:00Z"))
        try EPubBlockDAO(db: database.writer).insertAll([
            EPubBlockRecord(
                id: "receipt-block", audiobookID: audiobookID,
                spineHref: "chapter.xhtml", spineIndex: 0, blockIndex: 0,
                sequenceIndex: 0, blockKind: "paragraph", text: "Narratable source.",
                htmlContent: nil, cardColor: nil, chapterThemeColor: nil, imagePath: nil,
                chapterIndex: 0, isHidden: false, hiddenReason: nil, isFrontMatter: false,
                wordCount: nil, markers: nil, textFormats: nil, narrationText: nil,
                sourceChapterKey: entryID.uuidString, createdAt: nil, modifiedAt: nil)
        ])
        let articleBlocks = [
            ArticleBlock(
                id: "article-block", stableOrdinal: 0, kind: .paragraph,
                text: "Narratable source.", sourceURL: nil, imageCandidateURL: nil,
                caption: nil, codeLanguage: nil)
        ]
        let manifest = AnthologyBuildManifest(
            schemaVersion: 1, anthologyID: anthologyID, revision: 1,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)", title: "Anthology",
            subtitle: nil, creator: "Various Authors", language: "en", coverPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_775_000_000),
            chapters: [
                AnthologyChapterManifest(
                    entryID: entryID, captureID: UUID(), articleRevisionID: UUID(),
                    stableSlot: 0, order: 0, title: "Chapter 1", author: nil,
                    siteName: nil, sourceURL: URL(string: "https://example.test/one")!,
                    capturedAt: Date(timeIntervalSince1970: 1_775_000_000), voiceID: nil,
                    blocks: articleBlocks,
                    readableContentSHA256: ArticleWorkshopDigest.readableContent(
                        blocks: articleBlocks))
            ])
        let data = try JSONEncoder.articleWorkshop.encode(manifest)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var build = AnthologyBuildRecord(
            id: UUID().uuidString, anthologyID: anthologyID.uuidString, revision: 1,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: validDigest ? digest : String(repeating: "0", count: 64),
            epubPath: nil, epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID, status: "succeeded", errorCode: nil,
            createdAt: "2026-08-02T12:00:00Z")
        try database.writer.write { db in try build.insert(db) }
        return audiobookID
    }
}
