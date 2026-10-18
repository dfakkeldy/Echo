// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct AudiolessEPUBCoverImportTests {
    private let coverJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    @Test func persistAudiobookBackfillsCoverFromSiblingEPUB() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-cover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeEPUBArchive(to: folder.appendingPathComponent("book.epub"))

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)

        let audiobook = try #require(try AudiobookDAO(db: db.writer).get(folder.absoluteString))
        let coverPath = try #require(audiobook.coverArtPath)
        let coverURL = FileLocations.libraryCoversDirectory.appending(path: coverPath)
        defer { try? FileManager.default.removeItem(at: coverURL) }
        #expect(try Data(contentsOf: coverURL) == coverJPEG)
    }

    private func writeEPUBArchive(to dest: URL) throws {
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
            "OEBPS/content.opf",
            data: Data(
                """
                <?xml version="1.0"?><package><metadata><meta name="cover" content="cov"/></metadata>
                <manifest><item id="cov" href="cover.jpg" media-type="image/jpeg"/></manifest></package>
                """.utf8),
            to: archive)
        try addEntry("OEBPS/cover.jpg", data: coverJPEG, to: archive)
    }

    private func addEntry(_ path: String, data: Data, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
            position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }
}
