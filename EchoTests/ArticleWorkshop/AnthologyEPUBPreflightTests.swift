// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@Suite(.serialized)
struct AnthologyEPUBPreflightTests {
    @Test func acceptsBuilderOutputAndReturnsMatchingReceipt() throws {
        let fixture = try AnthologyEPUBPreflightFixture()
        defer { fixture.removeFiles() }
        let manifest = fixture.manifest()
        let output = fixture.root.appending(path: "valid.epub")
        let built = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: manifest, to: output)

        let checked = try AnthologyEPUBPreflight().validate(
            epubAt: output,
            against: manifest)

        #expect(checked == built)
    }

    @Test(arguments: [
        AnthologyEPUBPreflightFixture.Mutation.badMimetype,
        .missingContainer,
        .malformedPackage,
        .brokenSpineReference,
        .brokenNavigationReference,
        .duplicateChapterID,
        .credentialSourceURL,
        .identifierMismatch,
        .revisionMismatch,
        .manifestDigestMismatch,
        .undeclaredAsset,
        .wrongMediaType,
        .invalidStableBlockID,
        .remoteChapterImage,
        .remoteStylesheetReference,
        .tamperedStylesheet,
        .renamedPackageManifest,
        .renamedPackageSpine,
        .wrongXHTMLRoot,
        .wrongXHTMLNamespace,
    ])
    func rejectsTamperedArchiveMatrix(
        mutation: AnthologyEPUBPreflightFixture.Mutation
    ) throws {
        let fixture = try AnthologyEPUBPreflightFixture()
        defer { fixture.removeFiles() }
        let manifest = fixture.manifest()
        let valid = fixture.root.appending(path: "valid-\(mutation.rawValue).epub")
        _ = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: manifest, to: valid)
        let tampered = fixture.root.appending(path: "tampered-\(mutation.rawValue).epub")
        try fixture.rewrite(valid, to: tampered, mutation: mutation)

        #expect(throws: AnthologyEPUBPreflight.Error.self) {
            _ = try AnthologyEPUBPreflight().validate(
                epubAt: tampered,
                against: manifest)
        }
    }

    @Test func rejectsUnsafeAndDuplicateNormalizedArchivePaths() throws {
        let fixture = try AnthologyEPUBPreflightFixture()
        defer { fixture.removeFiles() }
        let manifest = fixture.manifest()
        let valid = fixture.root.appending(path: "valid.epub")
        _ = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: manifest, to: valid)

        for path in ["/absolute.xhtml", "../escape.xhtml", "EPUB\\evil.xhtml", "EPUB//empty.xhtml"]
        {
            let tampered = fixture.root.appending(
                path: "unsafe-\(UUID().uuidString).epub")
            try fixture.rewrite(valid, to: tampered, extraPath: path)
            #expect(throws: AnthologyEPUBPreflight.Error.self) {
                _ = try AnthologyEPUBPreflight().validate(
                    epubAt: tampered,
                    against: manifest)
            }
        }

        let duplicate = fixture.root.appending(path: "duplicate.epub")
        try fixture.rewrite(valid, to: duplicate, duplicatePath: "EPUB/nav.xhtml")
        #expect(throws: AnthologyEPUBPreflight.Error.self) {
            _ = try AnthologyEPUBPreflight().validate(
                epubAt: duplicate,
                against: manifest)
        }
    }

    @Test func rejectsResultDigestMismatchWithoutTreatingExpectedDigestAsArchiveTruth() throws {
        let fixture = try AnthologyEPUBPreflightFixture()
        defer { fixture.removeFiles() }
        let manifest = fixture.manifest()
        let valid = fixture.root.appending(path: "valid.epub")
        let result = try AnthologyEPUBBuilder(workshopRoot: fixture.workshopRoot)
            .build(manifest: manifest, to: valid)

        #expect(throws: AnthologyEPUBPreflight.Error.resultDigestMismatch) {
            try AnthologyEPUBPreflight().validate(
                result: AnthologyEPUBBuildResult(
                    temporaryURL: result.temporaryURL,
                    epubSHA256: String(repeating: "0", count: 64),
                    manifestSHA256: result.manifestSHA256,
                    identifier: result.identifier,
                    revision: result.revision),
                against: manifest)
        }
    }

    @Test func abortsExtractionOnTheFirstOverflowingChunk() throws {
        var buffer = AnthologyEPUBExtractionBuffer(maxBytes: 4)
        try buffer.consume(Data([0, 1, 2, 3]))

        #expect(throws: AnthologyEPUBExtractionBuffer.Error.limitExceeded) {
            try buffer.consume(Data([4]))
        }
        #expect(buffer.data == Data([0, 1, 2, 3]))
    }
}

struct AnthologyEPUBPreflightFixture {
    enum Mutation: String, CaseIterable, Sendable {
        case badMimetype
        case missingContainer
        case malformedPackage
        case brokenSpineReference
        case brokenNavigationReference
        case duplicateChapterID
        case credentialSourceURL
        case identifierMismatch
        case revisionMismatch
        case manifestDigestMismatch
        case undeclaredAsset
        case wrongMediaType
        case invalidStableBlockID
        case remoteChapterImage
        case remoteStylesheetReference
        case tamperedStylesheet
        case renamedPackageManifest
        case renamedPackageSpine
        case wrongXHTMLRoot
        case wrongXHTMLNamespace
    }

    let root: URL
    let workshopRoot: URL
    private let anthologyID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "AnthologyEPUBPreflightTests-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        workshopRoot = root.appending(path: "Workshop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workshopRoot, withIntermediateDirectories: true)
    }

    func manifest() -> AnthologyBuildManifest {
        let blocks = [
            ArticleBlock(
                id: "article-DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD-b5",
                stableOrdinal: 5,
                kind: .paragraph,
                text: "A bounded chapter.",
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil)
        ]
        let chapter = AnthologyChapterManifest(
            entryID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            captureID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            articleRevisionID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            stableSlot: 5,
            order: 0,
            title: "Chapter",
            author: "Writer",
            siteName: "Example",
            sourceURL: URL(string: "https://example.test/article")!,
            capturedAt: Date(timeIntervalSince1970: 1_735_600_000),
            voiceID: nil,
            blocks: blocks,
            readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: blocks))
        return AnthologyBuildManifest(
            schemaVersion: 1,
            anthologyID: anthologyID,
            revision: 2,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)",
            title: "Preflight Fixture",
            subtitle: nil,
            creator: "Echo Editor",
            language: "en",
            coverPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_600),
            chapters: [chapter])
    }

    func rewrite(
        _ source: URL,
        to destination: URL,
        mutation: Mutation? = nil,
        extraPath: String? = nil,
        duplicatePath: String? = nil
    ) throws {
        let sourceArchive = try Archive(url: source, accessMode: .read)
        let destinationArchive = try Archive(url: destination, accessMode: .create)
        for entry in sourceArchive {
            if mutation == .missingContainer, entry.path == "META-INF/container.xml" {
                continue
            }
            var data = try extract(entry, from: sourceArchive)
            if let mutation {
                data = mutate(data, at: entry.path, mutation: mutation)
            }
            try add(
                entry.path,
                data: data,
                compressed: entry.path != "mimetype",
                to: destinationArchive)
            if duplicatePath == entry.path {
                try add(
                    entry.path,
                    data: data,
                    compressed: true,
                    to: destinationArchive)
            }
        }
        if mutation == .undeclaredAsset {
            try add(
                "EPUB/images/undeclared.png",
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                compressed: true,
                to: destinationArchive)
        }
        if let extraPath {
            try add(extraPath, data: Data("extra".utf8), compressed: true, to: destinationArchive)
        }
    }

    private func mutate(_ data: Data, at path: String, mutation: Mutation) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let changed: String
        switch mutation {
        case .badMimetype where path == "mimetype":
            changed = "application/zip"
        case .malformedPackage where path == "EPUB/package.opf":
            changed = text.replacingOccurrences(of: "</package>", with: "")
        case .brokenSpineReference where path == "EPUB/package.opf":
            changed = text.replacingOccurrences(
                of: "idref=\"chapter-s5\"",
                with: "idref=\"missing\"")
        case .brokenNavigationReference where path == "EPUB/nav.xhtml":
            changed = text.replacingOccurrences(
                of: "articles/article-s5.xhtml",
                with: "articles/missing.xhtml")
        case .duplicateChapterID where path == "EPUB/articles/article-s5.xhtml":
            changed = text.replacingOccurrences(
                of: "</body>",
                with: "<p id=\"echo-s5-b1005\">duplicate</p></body>")
        case .credentialSourceURL where path == "EPUB/articles/article-s5.xhtml":
            changed = text.replacingOccurrences(
                of: "https://example.test/article",
                with: "https://reader:secret@example.test/article")
        case .identifierMismatch where path == "EPUB/package.opf":
            changed = text.replacingOccurrences(
                of: "urn:uuid:\(anthologyID.uuidString)",
                with: "urn:uuid:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        case .revisionMismatch where path == "EPUB/package.opf":
            changed = text.replacingOccurrences(
                of: ">2</meta>",
                with: ">999</meta>")
        case .manifestDigestMismatch where path == "EPUB/package.opf":
            changed = text.replacingOccurrences(
                of: manifestDigest(),
                with: String(repeating: "0", count: 64))
        case .wrongMediaType where path == "EPUB/package.opf":
            changed = text.replacingOccurrences(
                of: "media-type=\"application/xhtml+xml\"",
                with: "media-type=\"image/jpeg\"",
                options: [],
                range: text.range(of: "media-type=\"application/xhtml+xml\""))
        case .invalidStableBlockID where path == "EPUB/articles/article-s5.xhtml":
            changed = text.replacingOccurrences(
                of: "echo-s5-b1005",
                with: "echo-s6-b1005")
        case .remoteChapterImage where path == "EPUB/articles/article-s5.xhtml":
            changed = text.replacingOccurrences(
                of: "</body>",
                with: #"<img src="https://tracker.example/pixel.gif" alt="tracker"/></body>"#)
        case .remoteStylesheetReference where path == "EPUB/articles/article-s5.xhtml":
            changed = text.replacingOccurrences(
                of: #"href="../styles.css""#,
                with: #"href="https://tracker.example/styles.css""#)
        case .tamperedStylesheet where path == "EPUB/styles.css":
            changed = text + "\n@import url(\"https://tracker.example/styles.css\");"
        case .renamedPackageManifest where path == "EPUB/package.opf":
            changed =
                text
                .replacingOccurrences(of: "<manifest>", with: "<section>")
                .replacingOccurrences(of: "</manifest>", with: "</section>")
        case .renamedPackageSpine where path == "EPUB/package.opf":
            changed =
                text
                .replacingOccurrences(of: "<spine>", with: "<section>")
                .replacingOccurrences(of: "</spine>", with: "</section>")
        case .wrongXHTMLRoot where path == "EPUB/nav.xhtml":
            changed =
                text
                .replacingOccurrences(of: "<html xmlns=", with: "<section xmlns=")
                .replacingOccurrences(of: "</html>", with: "</section>")
        case .wrongXHTMLNamespace where path == "EPUB/articles/article-s5.xhtml":
            changed = text.replacingOccurrences(
                of: "http://www.w3.org/1999/xhtml",
                with: "https://example.test/not-xhtml")
        default:
            return data
        }
        return Data(changed.utf8)
    }

    private func manifestDigest() -> String {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(manifest())
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func add(
        _ path: String,
        data: Data,
        compressed: Bool,
        to archive: Archive
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: Date(timeIntervalSince1970: 1_735_689_600),
            compressionMethod: compressed ? .deflate : .none
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}
