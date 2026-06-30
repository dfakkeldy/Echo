// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

/// The EPUB cover lives in the OPF manifest (`<meta name="cover">` /
/// `properties="cover-image"`), never as an inline content image block. These
/// tests pin the export/cover paths to resolve it from the OPF — so a book like
/// "Everything but the Code" (cover declared only in the OPF, first inline image
/// deep in chapter 1) exports its real cover, not the first body illustration.
@Suite struct OPFCoverExportWiringTests {

    private let coverJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
    private let contentPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// EPUB 2 OPF that declares its cover via `<meta name="cover">` only — the
    /// cover image is NOT referenced by any inline `<img>`.
    private func opf(coverHref: String) -> String {
        """
        <?xml version="1.0"?><package><metadata><meta name="cover" content="cov"/></metadata>
        <manifest><item id="cov" href="\(coverHref)" media-type="image/jpeg"/></manifest></package>
        """
    }

    /// Writes a minimal zipped `.epub` (container + OPF + cover image) to `dest`.
    private func writeEPUBArchive(to dest: URL, coverRelPath: String) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        try addEntry(
            "META-INF/container.xml",
            data: Data(
                """
                <?xml version="1.0"?><container><rootfiles>
                <rootfile full-path="OEBPS/content.opf"/></rootfiles></container>
                """.utf8),
            to: archive)
        try addEntry(
            "OEBPS/content.opf", data: Data(opf(coverHref: coverRelPath).utf8), to: archive)
        try addEntry("OEBPS/\(coverRelPath)", data: coverJPEG, to: archive)
    }

    private func addEntry(_ path: String, data: Data, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
            position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    /// An on-disk content image plus a front-matter image block pointing at it —
    /// what the legacy "first front-matter image" heuristic would have picked.
    private func contentImageBlock() throws -> (URL, EPubBlockRecord) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try contentPNG.write(to: url)
        let block = EPubBlockRecord(
            id: "img0", audiobookID: "b", spineHref: "ch1.html", spineIndex: 5, blockIndex: 0,
            sequenceIndex: 10, blockKind: EPubBlockRecord.Kind.image.rawValue, text: nil,
            imagePath: url.path, chapterIndex: 0, isHidden: false, isFrontMatter: true)
        return (url, block)
    }

    // MARK: Gap 1 — headless .epubFile export

    @Test func headlessRunnerPrefersOPFCoverOverInlineImageForEpubFile() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        try writeEPUBArchive(to: archive, coverRelPath: "Cover.jpg")
        defer { try? FileManager.default.removeItem(at: archive) }

        let (contentURL, block) = try contentImageBlock()
        defer { try? FileManager.default.removeItem(at: contentURL) }

        // Mirrors the runner's `.epubFile` source: an archive URL, no expanded dir.
        let resolved = HeadlessNarrationRunner.coverData(
            epubArchiveURL: archive, expandedEPUBDir: nil, blocks: [block])
        #expect(resolved == coverJPEG)
    }

    @Test func headlessRunnerFallsBackToInlineImageWhenNoOPFCover() throws {
        let (contentURL, block) = try contentImageBlock()
        defer { try? FileManager.default.removeItem(at: contentURL) }

        // No EPUB source (e.g. PDF) → only the inline-image heuristic remains.
        let resolved = HeadlessNarrationRunner.coverData(
            epubArchiveURL: nil, expandedEPUBDir: nil, blocks: [block])
        #expect(resolved == contentPNG)
    }

    // MARK: Gap 2 — live narrated-book export (ExportMetadataResolver)

    @Test func exportMetadataResolverUsesOPFCoverForFolderAudiobookID() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeEPUBArchive(
            to: folder.appendingPathComponent("book.epub"), coverRelPath: "Cover.jpg")

        let db = try DatabaseService(inMemory: ())
        let cover = ExportMetadataResolver.epubCoverData(
            audiobookID: folder.absoluteString, databaseWriter: db.writer)
        #expect(cover == coverJPEG)
    }

    // MARK: Shared primitive — coverData(forAudiobookID:)

    @Test func resolverFindsCoverForStandaloneEpubAudiobookID() throws {
        let epub = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        try writeEPUBArchive(to: epub, coverRelPath: "Cover.jpg")
        defer { try? FileManager.default.removeItem(at: epub) }

        #expect(EpubCoverResolver.coverData(forAudiobookID: epub.absoluteString) == coverJPEG)
    }

    @Test func resolverFindsCoverForFolderAudiobookID() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeEPUBArchive(
            to: folder.appendingPathComponent("book.epub"), coverRelPath: "Cover.jpg")

        #expect(EpubCoverResolver.coverData(forAudiobookID: folder.absoluteString) == coverJPEG)
    }

    @Test func resolverReturnsNilForNonFileAudiobookID() {
        #expect(EpubCoverResolver.coverData(forAudiobookID: "abs:remote-item-42") == nil)
    }
}
