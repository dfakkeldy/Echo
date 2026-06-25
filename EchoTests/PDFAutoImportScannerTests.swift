// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct PDFAutoImportScannerTests {
    private func makeFolderWithPDF() throws -> (
        db: DatabaseService, folderURL: URL, pdfURL: URL, audiobookID: String
    ) {
        let db = try DatabaseService(inMemory: ())
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let pdfURL = try TestPDFFixture.singleChapter(in: folderURL)
        let audiobookID = folderURL.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 120)",
                arguments: [audiobookID]
            )
        }

        return (db, folderURL, pdfURL, audiobookID)
    }

    private func cleanup(folderURL: URL) {
        try? FileManager.default.removeItem(at: folderURL)
    }

    @Test func scanAndImportPDFFile() async throws {
        let (db, folderURL, pdfURL, audiobookID) = try makeFolderWithPDF()
        defer { cleanup(folderURL: folderURL) }

        let imported = await PDFAutoImportScanner.importPDFFile(
            pdfURL: pdfURL,
            audiobookID: audiobookID,
            databaseService: db,
            chapters: [],
            duration: nil,
            force: true
        )

        #expect(imported)

        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)
        #expect(!blocks.isEmpty)
        #expect(blocks.first(where: { $0.chapterIndex != nil }) != nil)
    }

    @Test func multiPagePDFWithoutMarkersImportsPageBasedNarrationChapters() async throws {
        let db = try DatabaseService(inMemory: ())
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { cleanup(folderURL: folderURL) }

        let pdfURL = try TestPDFFixture.threePagesWithoutChapterMarkers(in: folderURL)
        let audiobookID = folderURL.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 120)",
                arguments: [audiobookID]
            )
        }

        let imported = await PDFAutoImportScanner.importPDFFile(
            pdfURL: pdfURL,
            audiobookID: audiobookID,
            databaseService: db,
            chapters: [],
            duration: nil,
            force: true
        )

        #expect(imported)

        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)
        let chapterIndices = Set(blocks.compactMap(\.chapterIndex))
        #expect(chapterIndices == Set([0, 1, 2]))

        let headings = blocks.filter { $0.blockKind == "heading" }.compactMap(\.text)
        #expect(headings == ["Page 1", "Page 2", "Page 3"])
    }

    @Test func scanAndImportIsIdempotentWhenForcedOff() async throws {
        let (db, folderURL, _, audiobookID) = try makeFolderWithPDF()
        defer { cleanup(folderURL: folderURL) }

        let first = await PDFAutoImportScanner.scanAndImportIfNeeded(
            folderURL: folderURL,
            databaseService: db,
            chapters: [],
            duration: nil
        )

        let second = await PDFAutoImportScanner.scanAndImportIfNeeded(
            folderURL: folderURL,
            databaseService: db,
            chapters: [],
            duration: nil
        )

        #expect(first == true)
        #expect(second == false)

        let count = try EPubBlockDAO(db: db.writer).count(for: audiobookID)
        #expect(count > 0)
    }
}
