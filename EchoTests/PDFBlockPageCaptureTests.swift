// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct PDFBlockPageCaptureTests {
    @Test func importPopulatesPdfBlockPageRows() async throws {
        let db = try DatabaseService(inMemory: ())
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        // threePagesWithoutChapterMarkers produces a 3-page PDF so we can assert
        // rows land on multiple page indices.
        let pdfURL = try TestPDFFixture.threePagesWithoutChapterMarkers(in: folderURL)
        let audiobookID = folderURL.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 120)",
                arguments: [audiobookID]
            )
        }

        _ = await PDFAutoImportScanner.importPDFFile(
            pdfURL: pdfURL,
            audiobookID: audiobookID,
            databaseService: db,
            chapters: [],
            duration: nil,
            force: true
        )

        let rows = try PDFBlockPageDAO(db: db.writer).rows(for: audiobookID)
        #expect(!rows.isEmpty)
        #expect(rows.contains { $0.pageIndex == 0 })
        #expect(rows.contains { $0.pageIndex == 1 })
    }
}
