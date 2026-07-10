// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct EpubMetadataResolverTests {

    @Test func resolvesTitleAndCreatorFromFixtureOPF() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epubDir = try TestEPUBFixture.twoChapters(in: tmp)

        let metadata = try #require(EpubMetadataResolver.metadata(expandedEPUBDir: epubDir))

        #expect(metadata.title == "Fixture Book")
        #expect(metadata.author == "Tester")
    }

    @Test func resolvesViaAudiobookIDForFolderContainingEPUB() throws {
        // Mirrors the Library row shape: the id is the book FOLDER's URL and the
        // epub sits inside it (expanded dir named *.epub, as imports stage it).
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try TestEPUBFixture.twoChapters(in: folder)
        try FileManager.default.moveItem(
            at: fixture, to: folder.appendingPathComponent("book.epub", isDirectory: true))

        let metadata = try #require(
            EpubMetadataResolver.metadata(forAudiobookID: folder.absoluteString))

        #expect(metadata.title == "Fixture Book")
        #expect(metadata.author == "Tester")
    }

    @Test func opfWithoutTitleOrCreatorYieldsNils() throws {
        // An OPF is found but declares neither dc:title nor dc:creator: the
        // resolver reports "resolved, empty" (non-nil tuple of nils) rather than
        // failing, so callers can distinguish it from a missing/unreadable epub.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-empty-\(UUID().uuidString)", isDirectory: true)
        let metaInf = dir.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """.utf8
        ).write(to: metaInf.appendingPathComponent("container.xml"))
        try Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:language>en</dc:language>
            </metadata>
            <manifest/>
            <spine/>
            </package>
            """.utf8
        ).write(to: dir.appendingPathComponent("content.opf"))

        let metadata = try #require(EpubMetadataResolver.metadata(expandedEPUBDir: dir))

        #expect(metadata.title == nil)
        #expect(metadata.author == nil)
    }

    @Test func unresolvableAudiobookIDReturnsNil() {
        #expect(EpubMetadataResolver.metadata(forAudiobookID: "not-a-file-url") == nil)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(EpubMetadataResolver.metadata(forAudiobookID: missing.absoluteString) == nil)
    }
}
