// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized)
struct AnthologyNarrationManifestResolverTests {
    @Test func ordinaryBookReturnsNil() throws {
        let fixture = try ManifestResolverFixture()

        #expect(try fixture.resolver.resolve(audiobookID: "ordinary") == nil)
    }

    @Test func validAnthologyReturnsFrozenManifestByAudiobookID() throws {
        let fixture = try ManifestResolverFixture()
        let expected = try fixture.insertSuccessfulBuild(audiobookID: "book-1")

        #expect(try fixture.resolver.resolve(audiobookID: "book-1") == expected)
    }

    @Test func matchingTamperedReceiptThrows() throws {
        let fixture = try ManifestResolverFixture()
        try fixture.insertTamperedBuild(audiobookID: "book-1")

        #expect(throws: AnthologyBuildManifestValidationError.self) {
            try fixture.resolver.resolve(audiobookID: "book-1")
        }
    }

    @Test func standardizedEPUBPathMatchesSuccessfulBuild() throws {
        let fixture = try ManifestResolverFixture()
        let expected = try fixture.insertSuccessfulBuild(
            audiobookID: "other-book",
            epubPath: fixture.epubURL.standardizedFileURL.path)
        let nonstandardURL = fixture.epubURL
            .deletingLastPathComponent()
            .appending(path: "nested", directoryHint: .isDirectory)
            .appending(path: "..")
            .appending(path: fixture.epubURL.lastPathComponent)

        #expect(
            try fixture.resolver.resolve(audiobookID: "book-1", epubURL: nonstandardURL) == expected)
    }

    @Test("Invalid successful manifests are rejected", arguments: [
        ManifestResolverMutation.unavailableVoice,
        .duplicateEntry,
        .readableContentDigest,
    ])
    func invalidSuccessfulManifestThrows(
        mutation: ManifestResolverMutation
    ) throws {
        let fixture = try ManifestResolverFixture()
        _ = try fixture.insertSuccessfulBuild(audiobookID: "book-1", mutation: mutation)

        #expect(throws: AnthologyBuildManifestValidationError.self) {
            try fixture.resolver.resolve(audiobookID: "book-1")
        }
    }

    @Test func failedBuildDoesNotShadowOlderSuccessfulBuild() throws {
        let fixture = try ManifestResolverFixture()
        let expected = try fixture.insertSuccessfulBuild(audiobookID: "book-1", revision: 1)
        try fixture.insertFailedBuild(audiobookID: "book-1", revision: 2)

        #expect(try fixture.resolver.resolve(audiobookID: "book-1") == expected)
    }
}

enum ManifestResolverMutation: CaseIterable, Sendable {
    case unavailableVoice
    case duplicateEntry
    case readableContentDigest
}

@MainActor
private struct ManifestResolverFixture {
    let database: DatabaseService
    let anthologyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let epubURL: URL

    init() throws {
        database = try DatabaseService(inMemory: ())
        epubURL = URL(fileURLWithPath: "/managed/anthologies/book-1.epub")
        let anthology = AnthologyRecord(
            id: anthologyID.uuidString,
            title: "Fixture anthology",
            subtitle: nil,
            creator: nil,
            coverPath: nil,
            nextStableSlot: 1,
            latestBuildRevision: 0,
            createdAt: "2026-08-02T12:00:00Z",
            modifiedAt: "2026-08-02T12:00:00Z")
        try AnthologyDAO(db: database.writer).save(anthology)
    }

    var resolver: AnthologyNarrationManifestResolver {
        AnthologyNarrationManifestResolver(db: database.writer)
    }

    func insertSuccessfulBuild(
        audiobookID: String,
        epubPath: String? = nil,
        revision: Int = 1,
        mutation: ManifestResolverMutation? = nil
    ) throws -> AnthologyBuildManifest {
        let manifest = try manifest(revision: revision, mutation: mutation)
        let data = try JSONEncoder.articleWorkshop.encode(manifest)
        var build = AnthologyBuildRecord(
            id: UUID().uuidString,
            anthologyID: anthologyID.uuidString,
            revision: revision,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: sha256(data),
            epubPath: epubPath,
            epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID,
            status: "succeeded",
            errorCode: nil,
            createdAt: "2026-08-02T12:00:00Z")
        try database.writer.write { db in try build.insert(db) }
        return manifest
    }

    func insertTamperedBuild(audiobookID: String) throws {
        let manifest = try manifest(revision: 1, mutation: nil)
        let data = try JSONEncoder.articleWorkshop.encode(manifest)
        var build = AnthologyBuildRecord(
            id: UUID().uuidString,
            anthologyID: anthologyID.uuidString,
            revision: 1,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: String(repeating: "0", count: 64),
            epubPath: epubURL.standardizedFileURL.path,
            epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID,
            status: "succeeded",
            errorCode: nil,
            createdAt: "2026-08-02T12:00:00Z")
        try database.writer.write { db in try build.insert(db) }
    }

    func insertFailedBuild(audiobookID: String, revision: Int) throws {
        let manifest = try manifest(revision: revision, mutation: nil)
        let data = try JSONEncoder.articleWorkshop.encode(manifest)
        var build = AnthologyBuildRecord(
            id: UUID().uuidString,
            anthologyID: anthologyID.uuidString,
            revision: revision,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: sha256(data),
            epubPath: epubURL.standardizedFileURL.path,
            epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID,
            status: "failed",
            errorCode: "fixture",
            createdAt: "2026-08-02T12:01:00Z")
        try database.writer.write { db in try build.insert(db) }
    }

    private func manifest(
        revision: Int,
        mutation: ManifestResolverMutation?
    ) throws -> AnthologyBuildManifest {
        let blocks = [
            ArticleBlock(
                id: "block-1",
                stableOrdinal: 0,
                kind: .paragraph,
                text: "Trusted content",
                sourceURL: URL(string: "https://example.test/article"),
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil)
        ]
        let chapter = AnthologyChapterManifest(
            entryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            captureID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            articleRevisionID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            stableSlot: 0,
            order: 0,
            title: "Trusted chapter",
            author: nil,
            siteName: nil,
            sourceURL: URL(string: "https://example.test/article")!,
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
            voiceID: mutation == .unavailableVoice ? "missing-voice" : nil,
            blocks: blocks,
            readableContentSHA256: mutation == .readableContentDigest
                ? String(repeating: "0", count: 64)
                : ArticleWorkshopDigest.readableContent(blocks: blocks))
        let chapters: [AnthologyChapterManifest]
        if mutation == .duplicateEntry {
            chapters = [
                chapter,
                AnthologyChapterManifest(
                    entryID: chapter.entryID,
                    captureID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
                    articleRevisionID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                    stableSlot: 1,
                    order: 1,
                    title: "Duplicate entry",
                    author: nil,
                    siteName: nil,
                    sourceURL: chapter.sourceURL,
                    capturedAt: chapter.capturedAt,
                    voiceID: nil,
                    blocks: blocks,
                    readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: blocks)),
            ]
        } else {
            chapters = [chapter]
        }
        return AnthologyBuildManifest(
            schemaVersion: 1,
            anthologyID: anthologyID,
            revision: revision,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)",
            title: "Fixture anthology",
            subtitle: nil,
            creator: "Various Authors",
            language: "en",
            coverPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_775_000_000),
            chapters: chapters)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
