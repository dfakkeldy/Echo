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
