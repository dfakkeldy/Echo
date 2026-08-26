// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Echo

/// Cover-art resolution for the m4b export. The resolver mirrors the app's
/// display-cover cascade so the exported file carries whatever art the user
/// already sees: embedded audio artwork → (narrated) EPUB cover → (imported)
/// folder sidecar, normalised to a JPEG/PNG `swift-audio-marker` can embed.
@Suite struct ExportMetadataResolverTests {

    // MARK: - Seeding

    /// Inserts the `audiobook` row (FK target) and one track whose
    /// `narrationVoice` decides narrated-vs-imported. `author`/`addedAt` are set
    /// only when an `author` is supplied so the end-to-end `resolve` test can
    /// assert them.
    private func seed(_ db: DatabaseService, narrationVoice: String?, author: String? = nil) throws
    {
        try db.write { db in
            if let author {
                try db.execute(
                    sql:
                        "INSERT INTO audiobook (id, title, author, duration, added_at) VALUES ('bk', 'Book', ?, 60, '2026-01-01T00:00:00Z')",
                    arguments: [author])
            } else {
                try db.execute(
                    sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk', 'Book', 60)")
            }
        }
        let track = TrackRecord(
            id: "t0", audiobookID: "bk", title: "Chapter 1", duration: 10,
            filePath: "file:///x.m4a", isEnabled: true, sortOrder: 0,
            playlistPosition: nil, narrationVoice: narrationVoice)
        try TrackDAO(db: db.writer).insertAll([track], audiobookID: "bk")
    }

    /// Inserts an `image` EPUB block pointing at an on-disk file. The cover is
    /// always stored as a front-matter image during real imports.
    private func seedImageBlock(
        _ db: DatabaseService, id: String, sequence: Int, imagePath: String,
        isFrontMatter: Bool
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                    (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, image_path, is_hidden, is_front_matter)
                    VALUES (?, 'bk', 'cover.xhtml', 0, 0, ?, 'image', ?, 1, ?)
                    """,
                arguments: [id, sequence, imagePath, isFrontMatter])
        }
    }

    // MARK: - Filesystem + image helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Encodes a tiny solid-colour image to the given container format via
    /// ImageIO — the same encoder the resolver normalises through, so JPEG/PNG
    /// fixtures here are guaranteed to carry the magic bytes the resolver checks.
    private func makeImageData(_ utType: UTType) -> Data {
        let width = 4
        let height = 4
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, utType.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    // MARK: - Narrated (EPUB) source

    @Test func narratedBookResolvesEPUBFrontMatterCover() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, narrationVoice: "af_heart")
        let dir = try makeTempDir()
        let coverData = makeImageData(.png)
        let coverURL = dir.appendingPathComponent("cover.png")
        try write(coverData, to: coverURL)
        try seedImageBlock(db, id: "b0", sequence: 0, imagePath: coverURL.path, isFrontMatter: true)

        // firstSourceURL is nil: a narrated book's cache files carry no embedded
        // artwork, so the cover must come from the EPUB block.
        let cover = await ExportMetadataResolver.resolveCoverArt(
            audiobookID: "bk", firstSourceURL: nil, databaseWriter: db.writer)

        #expect(cover == coverData)  // PNG passes through normalisation unchanged.
    }

    @Test func narratedBookPrefersFrontMatterImageOverBodyImage() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, narrationVoice: "af_heart")
        let dir = try makeTempDir()

        // A body image earlier in reading order, and the real cover (front
        // matter) later — the resolver must pick the front-matter one regardless
        // of sequence, matching the narration Now-Playing cover lookup.
        let bodyData = makeImageData(.png)
        let bodyURL = dir.appendingPathComponent("body.png")
        try write(bodyData, to: bodyURL)
        try seedImageBlock(
            db, id: "body", sequence: 1, imagePath: bodyURL.path, isFrontMatter: false)

        let coverData = makeImageData(.jpeg)
        let coverURL = dir.appendingPathComponent("cover.jpg")
        try write(coverData, to: coverURL)
        try seedImageBlock(
            db, id: "cover", sequence: 5, imagePath: coverURL.path, isFrontMatter: true)

        let cover = await ExportMetadataResolver.resolveCoverArt(
            audiobookID: "bk", firstSourceURL: nil, databaseWriter: db.writer)

        #expect(cover == coverData)
    }

    @Test func narratedBookWithMissingCoverFileReturnsNil() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, narrationVoice: "af_heart")
        // image_path points at a file that does not exist.
        try seedImageBlock(
            db, id: "b0", sequence: 0,
            imagePath: "/nonexistent/\(UUID().uuidString)/cover.png", isFrontMatter: true)

        let cover = await ExportMetadataResolver.resolveCoverArt(
            audiobookID: "bk", firstSourceURL: nil, databaseWriter: db.writer)

        #expect(cover == nil)
    }

    // MARK: - Imported source (folder sidecar)

    @Test func importedBookResolvesFolderSidecarCover() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, narrationVoice: nil)
        let dir = try makeTempDir()
        let coverData = makeImageData(.jpeg)
        try write(coverData, to: dir.appendingPathComponent("cover.jpg"))
        // A bogus source file: not real audio, so embedded-artwork lookup yields
        // nil and resolution falls through to the folder sidecar.
        let source = dir.appendingPathComponent("audio.m4a")
        try write(Data(), to: source)

        let cover = await ExportMetadataResolver.resolveCoverArt(
            audiobookID: "bk", firstSourceURL: source, databaseWriter: db.writer)

        #expect(cover == coverData)
    }

    @Test func importedBookPrefersCoverNamedSidecar() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, narrationVoice: nil)
        let dir = try makeTempDir()

        // "aaa.png" sorts first alphabetically, but a file literally named
        // "cover" must win.
        let otherData = makeImageData(.png)
        try write(otherData, to: dir.appendingPathComponent("aaa.png"))
        let coverData = makeImageData(.jpeg)
        try write(coverData, to: dir.appendingPathComponent("cover.jpg"))
        let source = dir.appendingPathComponent("audio.m4a")
        try write(Data(), to: source)

        let cover = await ExportMetadataResolver.resolveCoverArt(
            audiobookID: "bk", firstSourceURL: source, databaseWriter: db.writer)

        #expect(cover == coverData)
    }

    @Test func importedBookWithNoArtworkReturnsNil() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, narrationVoice: nil)
        let dir = try makeTempDir()
        let source = dir.appendingPathComponent("audio.m4a")
        try write(Data(), to: source)

        let cover = await ExportMetadataResolver.resolveCoverArt(
            audiobookID: "bk", firstSourceURL: source, databaseWriter: db.writer)

        #expect(cover == nil)
    }

    // MARK: - Format normalisation

    @Test func normalisationPassesThroughJPEGAndPNGUnchanged() {
        let jpeg = makeImageData(.jpeg)
        let png = makeImageData(.png)
        // Identity for the formats the embedder accepts — no needless re-encode,
        // so an already-tagged cover round-trips byte-for-byte.
        #expect(ExportMetadataResolver.normalizedArtworkData(jpeg) == jpeg)
        #expect(ExportMetadataResolver.normalizedArtworkData(png) == png)
    }

    @Test func normalisationTranscodesOtherFormatsToJPEG() throws {
        let tiff = makeImageData(.tiff)
        // Guard the premise: the fixture really is a non-JPEG/PNG container.
        #expect(Array(tiff.prefix(3)) != [0xFF, 0xD8, 0xFF])

        let normalised = try #require(ExportMetadataResolver.normalizedArtworkData(tiff))
        // Output is now a JPEG (FF D8 FF) the embedder can write.
        #expect(Array(normalised.prefix(3)) == [0xFF, 0xD8, 0xFF])
    }

    @Test func normalisationReturnsNilForNonImageBytes() {
        #expect(ExportMetadataResolver.normalizedArtworkData(Data("not an image".utf8)) == nil)
    }

    // MARK: - End-to-end wiring

    @Test func resolveStampsTitleAuthorAndCoverForNarratedBook() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, narrationVoice: "af_heart", author: "Some Author")
        let dir = try makeTempDir()
        let coverData = makeImageData(.png)
        let coverURL = dir.appendingPathComponent("cover.png")
        try write(coverData, to: coverURL)
        try seedImageBlock(db, id: "b0", sequence: 0, imagePath: coverURL.path, isFrontMatter: true)

        let meta = await ExportMetadataResolver.resolve(
            audiobookID: "bk", fallbackTitle: "Fallback",
            firstSourceURL: nil, databaseWriter: db.writer)

        #expect(meta.title == "Book")
        #expect(meta.author == "Some Author")
        #expect(meta.coverArt == coverData)
        // With author + cover both present, the export now runs silently instead
        // of prompting for missing metadata.
        #expect(meta.isComplete)
    }
}
