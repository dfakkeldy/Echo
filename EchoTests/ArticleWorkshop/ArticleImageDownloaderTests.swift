// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite(.serialized) struct ArticleImageDownloaderTests {
    @Test func acceptsDecodedJPEGAndPNGOnlyWithinImageBudgets() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ArticleURLProtocol.install { request in
            switch request.url?.lastPathComponent {
            case "image.png": .response(status: 200, mimeType: "image/png", data: png)
            case "image.jpg": .response(status: 200, mimeType: "image/jpeg", data: jpeg)
            default: .response(status: 200, mimeType: "image/gif", data: png)
            }
        }
        defer { ArticleURLProtocol.reset() }
        let downloader = ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration())

        let result = await downloader.localize(
            candidates: [
                URL(string: "https://example.test/image.png")!,
                URL(string: "https://example.test/image.jpg")!,
                URL(string: "https://example.test/image.gif")!,
            ],
            into: root)

        #expect(result.localURLs.count == 2)
        #expect(result.warnings.count == 1)
        #expect(result.localURLs.allSatisfy { $0.standardizedFileURL.deletingLastPathComponent() == root.standardizedFileURL })
        #expect(result.localURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func imageFailureLeavesReadableTextAndAddsWarning() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ArticleURLProtocol.install { _ in .response(status: 200, mimeType: "image/png", data: Data("not an image".utf8)) }
        defer { ArticleURLProtocol.reset() }
        let downloader = ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration())
        let result = await downloader.localize(
            candidates: [URL(string: "https://example.test/bad.png")!],
            into: root)
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: articleWorkshopFixtureEnvelope())

        #expect(result.localURLs.isEmpty)
        #expect(result.warnings == [.invalidImage])
        #expect(snapshot.contentState == .ready)
    }

    @Test func totalBudgetStopsBeforeStartingAnotherImageRequest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ArticleURLProtocol.install { _ in .response(status: 200, mimeType: "image/png", data: png) }
        defer { ArticleURLProtocol.reset() }
        let downloader = ArticleImageDownloader(
            sessionConfiguration: articleURLProtocolConfiguration(),
            maximumImages: 2,
            maximumSingleImageBytes: png.count,
            maximumTotalImageBytes: png.count)

        let result = await downloader.localize(candidates: [
            URL(string: "https://example.test/first.png")!,
            URL(string: "https://example.test/second.png")!,
        ], into: root)

        #expect(result.localURLs.count == 1)
        #expect(result.warnings == [.totalByteLimitReached])
        #expect(ArticleURLProtocol.requestCount == 1)
    }

    @Test func truncatedImageIsRejectedAfterCompleteDecodeValidation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ArticleURLProtocol.install { _ in
            .response(status: 200, mimeType: "image/png", data: Data(png.prefix(24)))
        }
        defer { ArticleURLProtocol.reset() }

        let result = await ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration())
            .localize(candidates: [URL(string: "https://example.test/truncated.png")!], into: root)

        #expect(result.localURLs.isEmpty)
        #expect(result.warnings == [.invalidImage])
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func refusesExistingOrSymlinkedDestinationsWithoutOverwritingFiles() async throws {
        let root = try temporaryRoot()
        let external = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let existing = root.appending(path: "image-0.png")
        let original = Data("do not replace".utf8)
        try original.write(to: existing, options: .withoutOverwriting)
        ArticleURLProtocol.install { _ in .response(status: 200, mimeType: "image/png", data: png) }
        defer { ArticleURLProtocol.reset() }
        let downloader = ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration())

        let existingResult = await downloader.localize(
            candidates: [URL(string: "https://example.test/image.png")!], into: root)
        let symlink = root.appending(path: "linked-root", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let symlinkResult = await downloader.localize(
            candidates: [URL(string: "https://example.test/image.png")!], into: symlink)

        #expect(existingResult.localURLs.isEmpty)
        #expect(existingResult.warnings == [.unsafeDestination])
        #expect(try Data(contentsOf: existing) == original)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .allSatisfy { $0.lastPathComponent.hasPrefix(".image-") == false })
        #expect(symlinkResult.localURLs.isEmpty)
        #expect(symlinkResult.warnings == [.unsafeDestination])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ArticleImageDownloaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var png: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL1nQAAAABJRU5ErkJggg==")!
    }

    private var jpeg: Data {
        Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/Aaf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/Aaf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/Ap//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IV//2gAMAwEAAgADAAAAEP/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8QH//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8QH//EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8QH//Z")!
    }
}
