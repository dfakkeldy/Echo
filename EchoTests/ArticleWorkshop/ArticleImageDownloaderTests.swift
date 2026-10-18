// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import zlib

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

    @Test func completeContainerWithCorruptCompressedPixelsIsRejectedByImmediateDecode() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var corrupt = png
        // Keep PNG chunk framing and IEND intact, but corrupt an IDAT byte.
        let idatOffset = try idatChunkOffset(in: corrupt)
        corrupt[idatOffset + 8] ^= 0xFF
        rewriteCRC(ofChunkAt: idatOffset, in: &corrupt)
        ArticleURLProtocol.install { _ in .response(status: 200, mimeType: "image/png", data: corrupt) }
        defer { ArticleURLProtocol.reset() }

        let result = await ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration())
            .localize(candidates: [URL(string: "https://example.test/corrupt.png")!], into: root)

        #expect(result.localURLs.isEmpty)
        #expect(result.warnings == [.invalidImage])
    }

    @Test func rejectsPNGWithNonconsecutiveIDATChunksEvenWhenChunkCRCsAreValid() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let malformed = try pngWithNonconsecutiveIDATChunks(from: png)
        ArticleURLProtocol.install { _ in .response(status: 200, mimeType: "image/png", data: malformed) }
        defer { ArticleURLProtocol.reset() }

        let result = await ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration())
            .localize(candidates: [URL(string: "https://example.test/nonconsecutive.png")!], into: root)

        #expect(result.localURLs.isEmpty)
        #expect(result.warnings == [.invalidImage])
    }

    @Test func acceptsMultiBufferPNGAndRejectsTruncatedOrCorruptVariants() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try png(width: 128, height: 128, interlaced: false)
        #expect(try decompressedScanlineByteCount(in: valid) > 8 * 1024)
        var corrupt = valid
        let idatOffset = try idatChunkOffset(in: corrupt)
        corrupt[idatOffset + 8] ^= 0xFF
        rewriteCRC(ofChunkAt: idatOffset, in: &corrupt)
        let truncated = Data(valid.dropLast(8))
        ArticleURLProtocol.install { request in
            switch request.url?.lastPathComponent {
            case "valid.png": .response(status: 200, mimeType: "image/png", data: valid)
            case "corrupt.png": .response(status: 200, mimeType: "image/png", data: corrupt)
            default: .response(status: 200, mimeType: "image/png", data: truncated)
            }
        }
        defer { ArticleURLProtocol.reset() }

        let result = await ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration()).localize(
            candidates: [
                URL(string: "https://example.test/valid.png")!,
                URL(string: "https://example.test/corrupt.png")!,
                URL(string: "https://example.test/truncated.png")!,
            ],
            into: root)

        #expect(result.localURLs.count == 1)
        #expect(result.warnings == [.invalidImage, .invalidImage])
    }

    @Test func acceptsAdam7PNGAndRejectsCorruptCounterpart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try png(width: 17, height: 19, interlaced: true)
        #expect(try interlaceMethod(in: valid) == 1)
        var corrupt = valid
        let idatOffset = try idatChunkOffset(in: corrupt)
        corrupt[idatOffset + 8] ^= 0xFF
        rewriteCRC(ofChunkAt: idatOffset, in: &corrupt)
        ArticleURLProtocol.install { request in
            .response(status: 200, mimeType: "image/png", data: request.url?.lastPathComponent == "valid.png" ? valid : corrupt)
        }
        defer { ArticleURLProtocol.reset() }

        let result = await ArticleImageDownloader(sessionConfiguration: articleURLProtocolConfiguration()).localize(
            candidates: [URL(string: "https://example.test/valid.png")!, URL(string: "https://example.test/corrupt.png")!],
            into: root)

        #expect(result.localURLs.count == 1)
        #expect(result.warnings == [.invalidImage])
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

    @Test func failedCandidatesDoNotShiftBlockMappingsAndDuplicateBytesShareOneAsset() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try png(width: 17, height: 19, interlaced: false)
        ArticleURLProtocol.install { request in
            request.url?.lastPathComponent == "failed.png"
                ? .response(status: 200, mimeType: "image/png", data: Data("bad".utf8))
                : .response(status: 200, mimeType: "image/png", data: valid)
        }
        defer { ArticleURLProtocol.reset() }
        let candidates = [
            ArticleImageCandidate(
                owningBlockID: "image-a",
                sourceURL: URL(string: "https://example.test/failed.png")!,
                altText: nil,
                caption: nil),
            ArticleImageCandidate(
                owningBlockID: "image-b",
                sourceURL: URL(string: "https://example.test/shared.png")!,
                altText: "Diagram",
                caption: nil),
            ArticleImageCandidate(
                owningBlockID: "image-c",
                sourceURL: URL(string: "https://example.test/shared-again.png")!,
                altText: nil,
                caption: "The same diagram."),
        ]

        let result = await ArticleImageDownloader(
            sessionConfiguration: articleURLProtocolConfiguration()
        ).localize(candidates: candidates, into: root)

        #expect(result.failures.map(\.owningBlockID) == ["image-a"])
        #expect(result.assets.map(\.owningBlockID) == ["image-b", "image-c"])
        #expect(result.assets[0].managedPath == result.assets[1].managedPath)
        #expect(result.localURLs.count == 1)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ArticleImageDownloaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var png: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURTNmmf////ENxh0AAAABYktHRAH/Ai3eAAAAB3RJTUUH6gcdBwQUEKHG6gAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNy0yOVQwNzowNDoyMCswMDowMAupiH8AAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDctMjlUMDc6MDQ6MjArMDA6MDB69DDDAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA3LTI5VDA3OjA0OjIwKzAwOjAwLeERHAAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAASUVORK5CYII=")!
    }

    private func idatPayloadOffset(in data: Data) throws -> Int {
        try idatChunkOffset(in: data) + 8
    }

    private func idatChunkOffset(in data: Data) throws -> Int {
        let bytes = [UInt8](data)
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
            if type == "IDAT" { return offset }
            offset += 12 + length
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func pngWithNonconsecutiveIDATChunks(from original: Data) throws -> Data {
        let idatOffset = try idatChunkOffset(in: original)
        let bytes = [UInt8](original)
        let length = Int(bytes[idatOffset]) << 24 | Int(bytes[idatOffset + 1]) << 16 | Int(bytes[idatOffset + 2]) << 8 | Int(bytes[idatOffset + 3])
        let payloadStart = idatOffset + 8
        let payload = Data(bytes[payloadStart..<(payloadStart + length)])
        guard payload.count > 1 else { throw CocoaError(.fileReadCorruptFile) }
        let split = payload.count / 2
        var result = Data(original.prefix(idatOffset))
        appendPNGChunk(type: "IDAT", payload: payload.prefix(split), to: &result)
        appendPNGChunk(type: "tEXt", payload: Data("note\u{0}separated".utf8), to: &result)
        appendPNGChunk(type: "IDAT", payload: payload.dropFirst(split), to: &result)
        result.append(original[(payloadStart + length + 4)...])
        return result
    }

    private func appendPNGChunk(type: String, payload: some Collection<UInt8>, to data: inout Data) {
        let payload = Array(payload)
        appendUInt32(UInt32(payload.count), to: &data)
        let type = Array(type.utf8)
        data.append(contentsOf: type)
        data.append(contentsOf: payload)
        appendUInt32(crc32(type + payload), to: &data)
    }

    private func rewriteCRC(ofChunkAt offset: Int, in data: inout Data) {
        let bytes = [UInt8](data)
        let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        let crcOffset = offset + 8 + length
        let crc = crc32(Array(bytes[(offset + 4)..<crcOffset]))
        data[crcOffset] = UInt8(truncatingIfNeeded: crc >> 24)
        data[crcOffset + 1] = UInt8(truncatingIfNeeded: crc >> 16)
        data[crcOffset + 2] = UInt8(truncatingIfNeeded: crc >> 8)
        data[crcOffset + 3] = UInt8(truncatingIfNeeded: crc)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    private func png(width: Int, height: Int, interlaced: Bool) throws -> Data {
        let passes = interlaced
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        var scanlines = Data()
        for (originX, originY, stepX, stepY) in passes {
            let passWidth = dimension(length: width, origin: originX, step: stepX)
            let passHeight = dimension(length: height, origin: originY, step: stepY)
            guard passWidth > 0, passHeight > 0 else { continue }
            for row in 0..<passHeight {
                scanlines.append(0)
                for column in 0..<passWidth {
                    scanlines.append(UInt8(truncatingIfNeeded: row * 31 + column * 17))
                }
            }
        }
        var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(scanlines.count))))
        var compressedCount = uLongf(compressed.count)
        let result = scanlines.withUnsafeBytes { source in
            compress2(
                &compressed,
                &compressedCount,
                source.bindMemory(to: Bytef.self).baseAddress!,
                uLong(scanlines.count),
                Z_BEST_SPEED)
        }
        guard result == Z_OK else { throw CocoaError(.fileWriteUnknown) }

        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var header = Data()
        appendUInt32(UInt32(width), to: &header)
        appendUInt32(UInt32(height), to: &header)
        header.append(contentsOf: [8, 0, 0, 0, interlaced ? 1 : 0])
        appendPNGChunk(type: "IHDR", payload: header, to: &data)
        appendPNGChunk(type: "IDAT", payload: compressed.prefix(Int(compressedCount)), to: &data)
        appendPNGChunk(type: "IEND", payload: [], to: &data)
        return data
    }

    private func dimension(length: Int, origin: Int, step: Int) -> Int {
        guard length > origin else { return 0 }
        return (length - origin + step - 1) / step
    }

    private func interlaceMethod(in data: Data) throws -> UInt8 {
        let bytes = [UInt8](data)
        guard bytes.count >= 29, bytes[12] == 73, bytes[13] == 72, bytes[14] == 68, bytes[15] == 82 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return bytes[28]
    }

    private func decompressedScanlineByteCount(in data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 29 else { throw CocoaError(.fileReadCorruptFile) }
        let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
        let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
        return (width + 1) * height
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private var jpeg: Data {
        Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/Aaf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/Aaf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/Ap//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IV//2gAMAwEAAgADAAAAEP/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8QH//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8QH//EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8QH//Z")!
    }
}
