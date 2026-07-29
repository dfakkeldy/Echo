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

    @Test func stalePartialPackageIsReconciledBeforeRetry() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let stalePartial = root.appending(path: ".\(envelope.captureID.uuidString).partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stalePartial, withIntermediateDirectories: true)

        let package = try ArticleCaptureStagingWriter(root: root).stage(envelope)

        #expect(FileManager.default.fileExists(atPath: package.path))
        #expect(FileManager.default.fileExists(atPath: stalePartial.path) == false)
    }

    @Test func publishedIncompletePackageIsReconciledBeforeRetry() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let interruptedWriter = ArticleCaptureStagingWriter(root: root) { point in
            guard point == .beforeCompletionMarker else { return }
            throw WriterInterruption.interrupted
        }

        #expect(throws: WriterInterruption.self) {
            _ = try interruptedWriter.stage(envelope)
        }
        let incomplete = root.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: incomplete.appending(path: "envelope.json").path))
        #expect(FileManager.default.fileExists(atPath: incomplete.appending(path: "complete").path) == false)

        let package = try ArticleCaptureStagingWriter(root: root).stage(envelope)

        #expect(FileManager.default.fileExists(atPath: package.appending(path: "complete").path))
    }

    @Test func oversizedEnvelopeIsRejectedWithoutPublishingSnapshot() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let captureID = UUID()
        let package = root.appending(path: captureID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(count: ArticleWorkshopLimits.maxEnvelopeBytes + 1).write(
            to: package.appending(path: "envelope.json"), options: .atomic)
        try Data().write(to: package.appending(path: "complete"), options: .atomic)
        let store = ArticleWorkshopFileStore(root: root.appending(path: "workshop", directoryHint: .isDirectory))

        #expect(throws: ArticleWorkshopFileStore.Error.self) {
            _ = try store.importEnvelope(at: package)
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "workshop/Captures/\(captureID.uuidString)/snapshot.json").path
        ) == false)
    }

    @Test func symlinkedEnvelopeIsRejected() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let package = root.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        let source = root.appending(path: "source.json")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONEncoder.articleWorkshop.encode(envelope).write(to: source, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: package.appending(path: "envelope.json"),
            withDestinationURL: source
        )
        try Data().write(to: package.appending(path: "complete"), options: .atomic)
        let store = ArticleWorkshopFileStore(root: root.appending(path: "workshop", directoryHint: .isDirectory))

        #expect(throws: ArticleWorkshopFileStore.Error.self) {
            _ = try store.importEnvelope(at: package)
        }
    }

    @Test func nonemptyCompletionMarkerIsRejected() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let package = root.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONEncoder.articleWorkshop.encode(envelope).write(
            to: package.appending(path: "envelope.json"), options: .atomic)
        try Data("not empty".utf8).write(to: package.appending(path: "complete"), options: .atomic)
        let store = ArticleWorkshopFileStore(root: root.appending(path: "workshop", directoryHint: .isDirectory))

        #expect(throws: ArticleWorkshopFileStore.Error.self) {
            _ = try store.importEnvelope(at: package)
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ArticleWorkshopFileStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum WriterInterruption: Error {
    case interrupted
}

func articleWorkshopFixtureEnvelope(
    captureID: UUID = UUID(),
    title: String = "A Small Article"
) -> ArticleCaptureEnvelope {
    ArticleCaptureEnvelope(
        schemaVersion: 1,
        captureID: captureID,
        capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
        method: .safariRenderedPage,
        sourceApplication: "com.apple.mobilesafari",
        payload: ReadabilityCapturePayload(
            sourceURL: "https://example.test/article",
            canonicalURL: "https://example.test/article",
            title: title,
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
