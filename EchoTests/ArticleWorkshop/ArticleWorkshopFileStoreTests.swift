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

    @Test func loadsOwnedSnapshotByCaptureIDAndIgnoresDatabasePackagePath() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let workshop = root.appending(path: "workshop", directoryHint: .isDirectory)
        let store = ArticleWorkshopFileStore(root: workshop)
        let envelope = articleWorkshopFixtureEnvelope(
            captureID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            contentXHTML: "<article><p>Owned body.</p></article>")
        let staged = try ArticleCaptureStagingWriter(root: root.appending(path: "staging")).stage(envelope)
        let imported = try store.importEnvelope(at: staged)
        let record = workshopCaptureRecord(
            envelope: envelope,
            digest: imported.sha256,
            packagePath: root.appending(path: "attacker-controlled").path)

        let snapshot = try store.loadSnapshot(for: record)

        #expect(snapshot.captureID == envelope.captureID)
        #expect(snapshot.blocks.map(\.text) == ["Owned body."])
    }

    @Test func loadSnapshotRejectsDigestMismatchAndSymlinkedOwnershipBoundary() throws {
        let root = try temporaryRoot()
        defer { try! FileManager.default.removeItem(at: root) }
        let realWorkshop = root.appending(path: "real-workshop", directoryHint: .isDirectory)
        let store = ArticleWorkshopFileStore(root: realWorkshop)
        let envelope = articleWorkshopFixtureEnvelope(
            captureID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let staged = try ArticleCaptureStagingWriter(root: root.appending(path: "staging")).stage(envelope)
        let imported = try store.importEnvelope(at: staged)

        #expect(throws: ArticleWorkshopFileStore.Error.self) {
            _ = try store.loadSnapshot(
                for: workshopCaptureRecord(
                    envelope: envelope,
                    digest: String(repeating: "0", count: 64),
                    packagePath: imported.snapshotURL.deletingLastPathComponent().path))
        }

        let symlinkWorkshop = root.appending(path: "linked-workshop", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: symlinkWorkshop,
            withDestinationURL: realWorkshop)
        #expect(throws: ArticleWorkshopFileStore.Error.self) {
            _ = try ArticleWorkshopFileStore(root: symlinkWorkshop).loadSnapshot(
                for: workshopCaptureRecord(
                    envelope: envelope,
                    digest: imported.sha256,
                    packagePath: imported.snapshotURL.deletingLastPathComponent().path))
        }
    }

    @Test func unchangedSnapshotLoadsAfterSingleFileValidation() throws {
        let fixture = try installedSnapshotFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let recorder = ValidationURLRecorder()
        let store = ArticleWorkshopFileStore(
            root: fixture.workshop,
            validationHook: { point, url in
                guard point == .afterRead else { return }
                recorder.append(url)
            })

        let snapshot = try store.loadSnapshot(for: fixture.record)

        #expect(snapshot.captureID == fixture.envelope.captureID)
        #expect(recorder.urls == [fixture.snapshotURL])
    }

    @Test func loadSnapshotRejectsAtomicSameLengthReplacementAfterRead() throws {
        let fixture = try installedSnapshotFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let byteCount = try Data(contentsOf: fixture.snapshotURL).count
        let replacement = Data(repeating: 0x78, count: byteCount)
        let store = ArticleWorkshopFileStore(
            root: fixture.workshop,
            validationHook: { point, url in
                guard point == .afterRead, url == fixture.snapshotURL else { return }
                try replacement.write(to: url, options: .atomic)
            })

        #expect {
            _ = try store.loadSnapshot(for: fixture.record)
        } throws: { error in
            guard
                case .fileChangedDuringValidation(let url) =
                    error as? ArticleWorkshopFileStore.Error
            else {
                return false
            }
            return url == fixture.snapshotURL
        }
    }

    @Test func loadSnapshotRejectsSameInodeSameSizeRewriteAfterRead() throws {
        let fixture = try installedSnapshotFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let byteCount = try Data(contentsOf: fixture.snapshotURL).count
        let replacement = Data(repeating: 0x79, count: byteCount)
        let store = ArticleWorkshopFileStore(
            root: fixture.workshop,
            validationHook: { point, url in
                guard point == .afterRead, url == fixture.snapshotURL else { return }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: replacement)
                try handle.synchronize()
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1)],
                    ofItemAtPath: url.path)
            })

        #expect {
            _ = try store.loadSnapshot(for: fixture.record)
        } throws: { error in
            guard
                case .fileChangedDuringValidation(let url) =
                    error as? ArticleWorkshopFileStore.Error
            else {
                return false
            }
            return url == fixture.snapshotURL
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ArticleWorkshopFileStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func workshopCaptureRecord(
        envelope: ArticleCaptureEnvelope,
        digest: String,
        packagePath: String
    ) -> ArticleCaptureRecord {
        ArticleCaptureRecord(
            id: envelope.captureID.uuidString,
            sourceURL: envelope.payload.sourceURL,
            canonicalURL: envelope.payload.canonicalURL,
            title: envelope.payload.title ?? "Untitled",
            author: envelope.payload.byline,
            siteName: envelope.payload.siteName,
            language: envelope.payload.language,
            publishedAt: envelope.payload.publishedTime,
            capturedAt: "2026-07-29T00:00:00Z",
            captureMethod: envelope.method,
            packagePath: packagePath,
            contentSHA256: digest,
            extractorVersion: "1",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: "2026-07-29T00:00:00Z",
            modifiedAt: "2026-07-29T00:00:00Z")
    }

    private func installedSnapshotFixture() throws -> (
        root: URL,
        workshop: URL,
        envelope: ArticleCaptureEnvelope,
        record: ArticleCaptureRecord,
        snapshotURL: URL
    ) {
        let root = try temporaryRoot()
        let workshop = root.appending(path: "workshop", directoryHint: .isDirectory)
        let envelope = articleWorkshopFixtureEnvelope(
            captureID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let staged = try ArticleCaptureStagingWriter(
            root: root.appending(path: "staging", directoryHint: .isDirectory)
        ).stage(envelope)
        let imported = try ArticleWorkshopFileStore(root: workshop).importEnvelope(at: staged)
        return (
            root,
            workshop,
            envelope,
            workshopCaptureRecord(
                envelope: envelope,
                digest: imported.sha256,
                packagePath: "/untrusted"),
            imported.snapshotURL)
    }
}

private enum WriterInterruption: Error {
    case interrupted
}

private nonisolated final class ValidationURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.withLock { storage }
    }

    func append(_ url: URL) {
        lock.withLock {
            storage.append(url)
        }
    }
}

func articleWorkshopFixtureEnvelope(
    captureID: UUID = UUID(),
    title: String = "A Small Article",
    contentXHTML: String = "<article><p>Body.</p></article>"
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
            contentXHTML: contentXHTML,
            textContent: "Body.",
            imageURLs: []
        )
    )
}
