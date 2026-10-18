// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZIPFoundation

@testable import Echo

@Suite(.serialized)
struct AnthologyEPUBBuilderTests {
    @Test func writesDeterministicEpub33WithRequiredArchiveLayout() throws {
        let fixture = try AnthologyEPUBFixture()
        defer { fixture.removeFiles() }
        let manifest = fixture.manifest()
        let firstURL = fixture.root.appending(path: "first.epub")
        let secondURL = fixture.root.appending(path: "second.epub")

        let first = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: manifest, to: firstURL)
        let second = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: manifest, to: secondURL)

        let firstData = try Data(contentsOf: firstURL)
        let secondData = try Data(contentsOf: secondURL)
        #expect(firstData == secondData)
        #expect(first.epubSHA256 == second.epubSHA256)
        #expect(first.epubSHA256 == fixture.sha256(firstData))
        #expect(first.manifestSHA256 == fixture.manifestSHA256(manifest))
        #expect(first.identifier == manifest.epubIdentifier)
        #expect(first.revision == manifest.revision)

        let archive = try Archive(url: firstURL, accessMode: .read)
        let entries = Array(archive)
        #expect(entries.first?.path == "mimetype")
        #expect(entries.first?.isCompressed == false)
        #expect(try fixture.data("mimetype", in: archive) == Data("application/epub+zip".utf8))
        #expect(
            try fixture.string("META-INF/container.xml", in: archive)
                .contains("full-path=\"EPUB/package.opf\""))
        #expect(entries.allSatisfy { ($0.fileAttributes[.modificationDate] as? Date) != nil })
    }

    @Test func ordersNavigationAndSpineByOrderButNamesChaptersByStableSlot() throws {
        let fixture = try AnthologyEPUBFixture()
        defer { fixture.removeFiles() }
        let manifest = fixture.manifest(chaptersInStorageOrder: true)
        let output = fixture.root.appending(path: "ordered.epub")

        _ = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: manifest, to: output)

        let archive = try Archive(url: output, accessMode: .read)
        let nav = try fixture.string("EPUB/nav.xhtml", in: archive)
        let package = try fixture.string("EPUB/package.opf", in: archive)
        let firstNav = try #require(nav.range(of: "articles/article-s42.xhtml"))
        let secondNav = try #require(nav.range(of: "articles/article-s7.xhtml"))
        #expect(firstNav.lowerBound < secondNav.lowerBound)
        let firstSpine = try #require(package.range(of: "idref=\"chapter-s42\""))
        let secondSpine = try #require(package.range(of: "idref=\"chapter-s7\""))
        #expect(firstSpine.lowerBound < secondSpine.lowerBound)
        #expect(archive["EPUB/articles/article-s42.xhtml"] != nil)
        #expect(archive["EPUB/articles/article-s7.xhtml"] != nil)
    }

    @Test func escapesEveryTextAndAttributeAndEmitsStableNarrationBoundaries() throws {
        let fixture = try AnthologyEPUBFixture()
        defer { fixture.removeFiles() }
        let output = fixture.root.appending(path: "escaped.epub")

        _ = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: fixture.manifest(hostileText: true), to: output)

        let archive = try Archive(url: output, accessMode: .read)
        let package = try fixture.string("EPUB/package.opf", in: archive)
        let nav = try fixture.string("EPUB/nav.xhtml", in: archive)
        let chapter = try fixture.string("EPUB/articles/article-s42.xhtml", in: archive)
        #expect(package.contains("Book &amp; &lt;One&gt; &quot;quoted&quot;"))
        #expect(nav.contains("First &amp; &lt;Chapter&gt;"))
        #expect(chapter.contains("First &amp; &lt;Chapter&gt;"))
        #expect(chapter.contains("A &amp; B &lt; C &gt; D"))
        #expect(chapter.contains("id=\"echo-s42-b0\""))
        #expect(chapter.contains("id=\"echo-s42-b1\""))
        #expect(chapter.contains("id=\"echo-s42-b2\""))
        #expect(chapter.contains("id=\"echo-s42-b1004\""))
        #expect(chapter.contains("data-echo-stable-slot=\"42\""))
        #expect(chapter.contains("data-echo-block-index=\"1004\""))
        #expect(chapter.contains("id=\"echo-s42-b900000\""))
        #expect(chapter.contains("data-echo-narration=\"skip\""))
        #expect(chapter.contains("https://example.test/read?a=1&amp;b=2"))
        #expect(chapter.contains("<script") == false)
    }

    @Test func embedsDeterministicDefaultCoverAndSafelyManagedUserCover() throws {
        let fixture = try AnthologyEPUBFixture()
        defer { fixture.removeFiles() }
        let generatedURL = fixture.root.appending(path: "generated.epub")

        _ = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: fixture.manifest(), to: generatedURL)

        let generated = try Archive(url: generatedURL, accessMode: .read)
        let generatedCover = try fixture.data("EPUB/images/cover.svg", in: generated)
        #expect(
            generatedCover == AnthologyCoverRenderer.generatedCover(manifest: fixture.manifest()))
        #expect(
            try fixture.string("EPUB/package.opf", in: generated)
                .contains("media-type=\"image/svg+xml\" properties=\"cover-image\""))

        let managedName = try fixture.installManagedPNG()
        let managedURL = fixture.root.appending(path: "managed.epub")
        _ = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: fixture.manifest(coverPath: managedName), to: managedURL)
        let managed = try Archive(url: managedURL, accessMode: .read)
        #expect(try fixture.data("EPUB/images/cover.png", in: managed) == fixture.png())
        #expect(
            try fixture.string("EPUB/package.opf", in: managed)
                .contains("media-type=\"image/png\" properties=\"cover-image\""))
    }

    @Test func failsClosedOnInvalidManifestUnsafeCoverAndUnmappedArticleImage() throws {
        let fixture = try AnthologyEPUBFixture()
        defer { fixture.removeFiles() }
        let builder = AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)

        #expect(throws: AnthologyEPUBBuilder.Error.invalidManifest) {
            _ = try builder.build(
                manifest: fixture.manifest(identifier: "https://example.test/book"),
                to: fixture.root.appending(path: "identifier.epub"))
        }
        #expect(throws: AnthologyEPUBBuilder.Error.unsafeAsset) {
            _ = try builder.build(
                manifest: fixture.manifest(coverPath: "../outside.png"),
                to: fixture.root.appending(path: "cover.epub"))
        }
        #expect(throws: AnthologyEPUBBuilder.Error.missingImageAssetMapping) {
            _ = try builder.build(
                manifest: fixture.manifest(includeImageBlock: true),
                to: fixture.root.appending(path: "image.epub"))
        }
        #expect(
            FileManager.default.fileExists(atPath: fixture.root.appending(path: "image.epub").path)
                == false)
    }

    @Test func acceptsThePersistedUndeterminedLanguageContract() throws {
        let fixture = try AnthologyEPUBFixture()
        defer { fixture.removeFiles() }
        let output = fixture.root.appending(path: "und.epub")

        let result = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: fixture.manifest(language: "und"), to: output)

        #expect(result.identifier == fixture.manifest().epubIdentifier)
        let archive = try Archive(url: output, accessMode: .read)
        #expect(try fixture.string("EPUB/nav.xhtml", in: archive).contains("xml:lang=\"und\""))
    }

    @Test func embedsDescriptorBackedArticleImageAsAccessibleFigure() throws {
        let fixture = try AnthologyEPUBFixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.manifestWithManagedArticleImage()
        let output = fixture.root.appending(path: "article-image.epub")

        _ = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: prepared.manifest, to: output)

        let archive = try Archive(url: output, accessMode: .read)
        #expect(try fixture.data(prepared.descriptor.archivePath, in: archive) == prepared.data)
        let package = try fixture.string("EPUB/package.opf", in: archive)
        let chapter = try fixture.string("EPUB/articles/article-s42.xhtml", in: archive)
        #expect(package.contains("href=\"images/article-\(prepared.descriptor.sha256).png\" media-type=\"image/png\""))
        #expect(chapter.contains("<figure"))
        #expect(chapter.contains("src=\"../images/article-\(prepared.descriptor.sha256).png\""))
        #expect(chapter.contains("alt=\"Harbour at sunrise\""))
        #expect(chapter.contains("<figcaption>Fishing boats returning home.</figcaption>"))
        #expect(chapter.contains("https://images.example.test/photo.png") == false)
    }
}

private struct AnthologyEPUBFixture {
    let root: URL
    let workshopRoot: URL
    let anthologyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "AnthologyEPUBTests-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        workshopRoot = root.appending(path: "Workshop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workshopRoot, withIntermediateDirectories: true)
    }

    func manifest(
        chaptersInStorageOrder: Bool = false,
        hostileText: Bool = false,
        coverPath: String? = nil,
        identifier: String? = nil,
        includeImageBlock: Bool = false,
        language: String = "en"
    ) -> AnthologyBuildManifest {
        let first = chapter(
            entry: "11111111-1111-1111-1111-111111111111",
            capture: "21111111-1111-1111-1111-111111111111",
            revision: "31111111-1111-1111-1111-111111111111",
            stableSlot: 42,
            order: 0,
            title: hostileText ? "First & <Chapter>" : "First Chapter",
            author: hostileText ? "A \"Writer\" & Co." : "A Writer",
            sourceURL: URL(string: "https://example.test/read?a=1&b=2")!,
            hostileText: hostileText,
            includeImageBlock: includeImageBlock)
        let second = chapter(
            entry: "12222222-2222-2222-2222-222222222222",
            capture: "22222222-2222-2222-2222-222222222222",
            revision: "32222222-2222-2222-2222-222222222222",
            stableSlot: 7,
            order: 1,
            title: "Second Chapter",
            author: nil,
            sourceURL: URL(string: "https://second.example.test/article")!,
            hostileText: false,
            includeImageBlock: false)
        return AnthologyBuildManifest(
            schemaVersion: 1,
            anthologyID: anthologyID,
            revision: 3,
            epubIdentifier: identifier ?? "urn:uuid:\(anthologyID.uuidString)",
            title: hostileText ? "Book & <One> \"quoted\"" : "A Small Book",
            subtitle: hostileText ? "Subtitle & <more>" : "Collected articles",
            creator: hostileText ? "Editor & <Friends>" : "Echo Editor",
            language: language,
            coverPath: coverPath,
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_600.25),
            chapters: chaptersInStorageOrder ? [second, first] : [first, second])
    }

    func chapter(
        entry: String,
        capture: String,
        revision: String,
        stableSlot: Int,
        order: Int,
        title: String,
        author: String?,
        sourceURL: URL,
        hostileText: Bool,
        includeImageBlock: Bool
    ) -> AnthologyChapterManifest {
        var blocks = [
            ArticleBlock(
                id: "article-\(capture)-b4",
                stableOrdinal: 4,
                kind: .paragraph,
                text: hostileText ? "A & B < C > D" : "Body for \(title).",
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil),
            ArticleBlock(
                id: "article-\(capture)-b8",
                stableOrdinal: 8,
                kind: .separator,
                text: nil,
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil),
        ]
        if includeImageBlock {
            blocks.append(
                ArticleBlock(
                    id: "article-\(capture)-b9",
                    stableOrdinal: 9,
                    kind: .image,
                    text: nil,
                    sourceURL: nil,
                    imageCandidateURL: URL(string: "https://images.example.test/photo.png"),
                    caption: "A photo",
                    codeLanguage: nil))
        }
        return AnthologyChapterManifest(
            entryID: UUID(uuidString: entry)!,
            captureID: UUID(uuidString: capture)!,
            articleRevisionID: UUID(uuidString: revision)!,
            stableSlot: stableSlot,
            order: order,
            title: title,
            author: author,
            siteName: hostileText ? "Site & <News>" : "Example",
            sourceURL: sourceURL,
            capturedAt: Date(timeIntervalSince1970: 1_735_600_000),
            voiceID: nil,
            blocks: blocks,
            readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: blocks))
    }

    func installManagedPNG() throws -> String {
        let directory =
            workshopRoot
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = png()
        let filename = "cover-\(sha256(data)).png"
        try data.write(to: directory.appending(path: filename))
        return filename
    }

    func manifestWithManagedArticleImage() throws -> (
        manifest: AnthologyBuildManifest,
        descriptor: ArticleImageAssetDescriptor,
        data: Data
    ) {
        let data = png()
        let digest = sha256(data)
        let captureID = UUID(uuidString: "21111111-1111-1111-1111-111111111111")!
        let blockID = "article-\(captureID.uuidString)-b9"
        let managedPath = "images/\(digest).png"
        let directory = workshopRoot
            .appending(path: "Captures", directoryHint: .isDirectory)
            .appending(path: captureID.uuidString, directoryHint: .isDirectory)
            .appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(digest).png"))
        let descriptor = ArticleImageAssetDescriptor(
            owningBlockID: blockID,
            managedPath: managedPath,
            archivePath: "EPUB/images/article-\(digest).png",
            mediaType: "image/png",
            sha256: digest,
            byteCount: data.count,
            pixelWidth: 1,
            pixelHeight: 1,
            sourceURL: URL(string: "https://images.example.test/photo.png")!,
            altText: "Harbour at sunrise",
            caption: "Fishing boats returning home.")
        var manifest = manifest(includeImageBlock: true)
        let chapters = manifest.chapters.map { chapter in
            let blocks = chapter.blocks.map { block in
                guard block.id == blockID else { return block }
                return ArticleBlock(
                    id: block.id,
                    stableOrdinal: block.stableOrdinal,
                    kind: block.kind,
                    text: block.text,
                    sourceURL: block.sourceURL,
                    imageCandidateURL: block.imageCandidateURL,
                    altText: descriptor.altText,
                    caption: descriptor.caption,
                    codeLanguage: block.codeLanguage)
            }
            return AnthologyChapterManifest(
                entryID: chapter.entryID,
                captureID: chapter.captureID,
                articleRevisionID: chapter.articleRevisionID,
                stableSlot: chapter.stableSlot,
                order: chapter.order,
                title: chapter.title,
                author: chapter.author,
                siteName: chapter.siteName,
                sourceURL: chapter.sourceURL,
                capturedAt: chapter.capturedAt,
                voiceID: chapter.voiceID,
                blocks: blocks,
                readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: blocks))
        }
        manifest = AnthologyBuildManifest(
            schemaVersion: 2,
            anthologyID: manifest.anthologyID,
            revision: manifest.revision,
            epubIdentifier: manifest.epubIdentifier,
            title: manifest.title,
            subtitle: manifest.subtitle,
            creator: manifest.creator,
            language: manifest.language,
            coverPath: manifest.coverPath,
            modifiedAt: manifest.modifiedAt,
            chapters: chapters,
            imageAssets: [descriptor],
            imageFailures: [])
        return (manifest, descriptor, data)
    }

    func png() -> Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
    }

    func data(_ path: String, in archive: Archive) throws -> Data {
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    func string(_ path: String, in archive: Archive) throws -> String {
        String(decoding: try data(path, in: archive), as: UTF8.self)
    }

    func manifestSHA256(_ manifest: AnthologyBuildManifest) -> String {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        return sha256(try! encoder.encode(manifest))
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}
