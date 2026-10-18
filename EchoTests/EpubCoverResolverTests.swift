// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

/// `EpubCoverResolver` pulls the cover from the OPF manifest (where EPUB covers
/// actually live), not from inline content image blocks.
@Suite struct EpubCoverResolverTests {

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    /// Builds a minimal expanded EPUB on disk and returns its root dir.
    private func makeEPUB(
        opf: String, coverRelPath: String?, coverBytes: Data?
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oebps = dir.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?><container><rootfiles>
        <rootfile full-path="OEBPS/content.opf"/></rootfiles></container>
        """.write(
            to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true,
            encoding: .utf8)
        try opf.write(
            to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        if let coverRelPath, let coverBytes {
            let coverURL = oebps.appendingPathComponent(coverRelPath)
            try FileManager.default.createDirectory(
                at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coverBytes.write(to: coverURL)
        }
        return dir
    }

    private func makeEPUBArchive(
        opf: String, coverRelPath: String?, coverBytes: Data?
    ) throws -> URL {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        let archive = try Archive(url: archiveURL, accessMode: .create)

        try addEntry(
            "META-INF/container.xml",
            data: Data(
                """
                <?xml version="1.0"?><container><rootfiles>
                <rootfile full-path="OEBPS/content.opf"/></rootfiles></container>
                """.utf8),
            to: archive)
        try addEntry("OEBPS/content.opf", data: Data(opf.utf8), to: archive)
        if let coverRelPath, let coverBytes {
            try addEntry("OEBPS/\(coverRelPath)", data: coverBytes, to: archive)
        }
        return archiveURL
    }

    private func addEntry(_ path: String, data: Data, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
            position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    @Test func resolvesEpub2CoverViaMeta() throws {
        let dir = try makeEPUB(
            opf: """
                <?xml version="1.0"?><package><metadata><meta name="cover" content="cov"/></metadata>
                <manifest><item id="cov" href="images/cover.jpg" media-type="image/jpeg"/></manifest></package>
                """,
            coverRelPath: "images/cover.jpg", coverBytes: jpeg)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(EpubCoverResolver.coverData(expandedEPUBDir: dir) == jpeg)
    }

    @Test func resolvesEpub3CoverViaProperties() throws {
        let dir = try makeEPUB(
            opf: """
                <?xml version="1.0"?><package><manifest>
                <item id="c" href="cover.png" media-type="image/png" properties="cover-image"/>
                </manifest></package>
                """,
            coverRelPath: "cover.png", coverBytes: Data([0x89, 0x50, 0x4E, 0x47]))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(
            EpubCoverResolver.coverData(expandedEPUBDir: dir) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func returnsNilWhenNoCoverDeclared() throws {
        let dir = try makeEPUB(
            opf: "<?xml version=\"1.0\"?><package><manifest></manifest></package>",
            coverRelPath: nil, coverBytes: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(EpubCoverResolver.coverData(expandedEPUBDir: dir) == nil)
    }

    @Test func resolvesCoverFromZippedEPUBArchive() throws {
        let archiveURL = try makeEPUBArchive(
            opf: """
                <?xml version="1.0"?><package><manifest>
                <item id="c" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
                </manifest></package>
                """,
            coverRelPath: "images/cover.jpg", coverBytes: jpeg)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        #expect(EpubCoverResolver.coverData(epubArchiveURL: archiveURL) == jpeg)
    }

    @Test func rejectsArchiveCoverPathEscapingEPUBRoot() throws {
        let archiveURL = try makeEPUBArchive(
            opf: """
                <?xml version="1.0"?><package><manifest>
                <item id="c" href="../../cover.jpg" media-type="image/jpeg" properties="cover-image"/>
                </manifest></package>
                """,
            coverRelPath: nil, coverBytes: nil)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        #expect(EpubCoverResolver.coverData(epubArchiveURL: archiveURL) == nil)
    }
}
