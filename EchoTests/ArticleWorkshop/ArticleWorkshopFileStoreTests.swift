// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ArticleWorkshopFileStoreTests {
    @Test func completionMarkerIsWrittenAfterEnvelope() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let envelope = articleWorkshopFixtureEnvelope()

        let package = try ArticleCaptureStagingWriter(root: root).stage(envelope)

        #expect(FileManager.default.fileExists(atPath: package.appending(path: "envelope.json").path))
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "complete").path))
        #expect(package.lastPathComponent == envelope.captureID.uuidString)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ArticleWorkshopFileStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

func articleWorkshopFixtureEnvelope() -> ArticleCaptureEnvelope {
    ArticleCaptureEnvelope(
        schemaVersion: 1,
        captureID: UUID(),
        capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
        method: .safariRenderedPage,
        sourceApplication: "com.apple.mobilesafari",
        payload: ReadabilityCapturePayload(
            sourceURL: "https://example.test/article",
            canonicalURL: "https://example.test/article",
            title: "A Small Article",
            byline: "A. Writer",
            siteName: "Example",
            language: "en",
            publishedTime: "2026-07-28",
            excerpt: "A fixture.",
            contentXHTML: "<article><p>Body.</p></article>",
            textContent: "Body.",
            imageURLs: []
        )
    )
}
