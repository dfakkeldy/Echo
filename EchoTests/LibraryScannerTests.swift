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
}
