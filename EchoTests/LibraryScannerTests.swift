// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct LibraryScannerTests {
    /// Builds: root/BookA/a.m4b, root/BookA/a.epub, root/Series/BookB/b.mp3,
    /// root/notes.txt (ignored). Expect two books, BookB carrying no EPUB.
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lib-scan-\(UUID().uuidString)", isDirectory: true)
        let bookA = root.appendingPathComponent("BookA", isDirectory: true)
        let bookB = root.appendingPathComponent("Series/BookB", isDirectory: true)
        try fm.createDirectory(at: bookA, withIntermediateDirectories: true)
        try fm.createDirectory(at: bookB, withIntermediateDirectories: true)
        try Data().write(to: bookA.appendingPathComponent("a.m4b"))
        try Data().write(to: bookA.appendingPathComponent("a.epub"))
        try Data().write(to: bookB.appendingPathComponent("b.mp3"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        return root
    }

    @Test func discoversOneBookPerAudioFolder() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = LibraryScanner.discoverBooks(in: root)
        let names = books.map { $0.folderURL.lastPathComponent }.sorted()
        #expect(names == ["BookA", "BookB"])
    }

    @Test func attachesCompanionEPUBWhenPresent() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = LibraryScanner.discoverBooks(in: root)
        let bookA = try #require(books.first { $0.folderURL.lastPathComponent == "BookA" })
        let bookB = try #require(books.first { $0.folderURL.lastPathComponent == "BookB" })
        #expect(bookA.companionEPUB?.lastPathComponent == "a.epub")
        #expect(bookB.companionEPUB == nil)
    }

    @Test func fallbackTitleUsesFolderName() throws {
        let book = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Books/The Hobbit", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Books/The Hobbit/01.m4b")],
            companionEPUB: nil)
        #expect(LibraryScanner.fallbackTitle(for: book) == "The Hobbit")
    }

    @Test func readMetadataEncodesSidecarCoverAsJPEG() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lib-cover-\(UUID().uuidString)", isDirectory: true)
        let bookFolder = root.appendingPathComponent("BookWithCover", isDirectory: true)
        try fm.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let audioURL = bookFolder.appendingPathComponent("01.m4b")
        try Data().write(to: audioURL)

        let pngData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        ))
        try pngData.write(to: bookFolder.appendingPathComponent("cover.png"))

        let book = DiscoveredBook(
            folderURL: bookFolder,
            audioFiles: [audioURL],
            companionEPUB: nil)
        let metadata = await LibraryScanner.readMetadata(for: book)
        let coverData = try #require(metadata.coverImageData)

        #expect(metadata.title == "BookWithCover")
        #expect(Array(coverData.prefix(3)) == [0xFF, 0xD8, 0xFF])
    }
}
