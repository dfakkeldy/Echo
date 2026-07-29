// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
struct SchemaV37ArticleWorkshopTests {
    @Test func v37CreatesWorkshopTablesAndRestrictsReferencedArticleDeletion() throws {
        let service = try DatabaseService(inMemory: ())
        let captureDAO = ArticleCaptureDAO(db: service.writer)
        let anthologyDAO = AnthologyDAO(db: service.writer)

        let tables = try service.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        #expect(tables.contains("article_capture"))
        #expect(tables.contains("article_revision"))
        #expect(tables.contains("anthology"))
        #expect(tables.contains("anthology_entry"))
        #expect(tables.contains("anthology_build"))

        try captureDAO.saveCapture(capture("capture-1"))
        try anthologyDAO.save(anthology("anthology-1"))
        _ = try anthologyDAO.addCapture("capture-1", to: "anthology-1")

        #expect(throws: (any Error).self) {
            try captureDAO.deleteCapture(id: "capture-1")
        }
        #expect(try captureDAO.capture(id: "capture-1") != nil)
    }

    private func capture(_ id: String) -> ArticleCaptureRecord {
        ArticleCaptureRecord(
            id: id,
            sourceURL: "https://example.com/articles/\(id)",
            canonicalURL: "https://example.com/articles/\(id)",
            title: "Article \(id)",
            author: "Author",
            siteName: "Example",
            language: "en",
            publishedAt: "2026-07-28T12:00:00Z",
            capturedAt: "2026-07-28T12:01:00Z",
            captureMethod: .safariRenderedPage,
            packagePath: "/captures/\(id)",
            contentSHA256: "digest-\(id)",
            extractorVersion: "1",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: "2026-07-28T12:01:00Z",
            modifiedAt: "2026-07-28T12:01:00Z"
        )
    }

    private func anthology(_ id: String) -> AnthologyRecord {
        AnthologyRecord(
            id: id,
            title: "Anthology \(id)",
            subtitle: nil,
            creator: nil,
            coverPath: nil,
            nextStableSlot: 0,
            latestBuildRevision: 0,
            createdAt: "2026-07-28T12:01:00Z",
            modifiedAt: "2026-07-28T12:01:00Z"
        )
    }
}
