// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import zlib

nonisolated enum ArticleImageLocalizationWarning: String, Codable, Equatable, Sendable {
    case invalidURL
    case downloadFailed
    case invalidContentType
    case responseTooLarge
    case invalidImage
    case totalByteLimitReached
    case unsafeDestination
}

nonisolated struct ArticleImageLocalization: Sendable {
    let localURLs: [URL]
    let warnings: [ArticleImageLocalizationWarning]
}

private nonisolated enum ArticleImageType: Sendable {
    case jpeg
    case png

    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
}

@MainActor
struct ArticleImageDownloader {
    private let sessionConfiguration: URLSessionConfiguration
    private let maximumImages: Int
    private let maximumSingleImageBytes: Int
    private let maximumTotalImageBytes: Int

    init(
        sessionConfiguration: URLSessionConfiguration = ArticleURLCaptureService.ephemeralConfiguration(),
        maximumImages: Int = ArticleWorkshopLimits.maxImages,
        maximumSingleImageBytes: Int = ArticleWorkshopLimits.maxSingleImageBytes,
        maximumTotalImageBytes: Int = ArticleWorkshopLimits.maxTotalImageBytes
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.maximumImages = maximumImages
        self.maximumSingleImageBytes = maximumSingleImageBytes
        self.maximumTotalImageBytes = maximumTotalImageBytes
    }

    func localize(candidates: [URL], into captureDirectory: URL) async -> ArticleImageLocalization {
        let root = captureDirectory.standardizedFileURL
        guard Self.isSafeDirectory(root) else {
            return ArticleImageLocalization(localURLs: [], warnings: [.unsafeDestination])
        }
        var localURLs: [URL] = []
        var warnings: [ArticleImageLocalizationWarning] = []
        var totalBytes = 0

        for candidate in candidates where localURLs.count < maximumImages {
            let remainingBytes = maximumTotalImageBytes - totalBytes
            guard remainingBytes > 0 else {
                warnings.append(.totalByteLimitReached)
                break
            }
            guard let url = ArticleNetworkURLPolicy.normalized(candidate) else {
                warnings.append(.invalidURL)
                continue
            }
            let loader = ArticleBoundedURLLoader(
                configuration: sessionConfiguration,
                acceptedMIMETypes: ["image/jpeg", "image/png"],
                maximumBytes: min(maximumSingleImageBytes, remainingBytes))
            let response: ArticleBoundedURLLoader.Response
            do {
                response = try await loader.load(url: url)
            } catch let error as ArticleBoundedURLLoader.Error {
                warnings.append(Self.warning(for: error))
                continue
            } catch {
                warnings.append(.downloadFailed)
                continue
            }
            let imageType = await Task.detached(priority: .userInitiated) {
                Self.validatedImageType(data: response.data, mimeType: response.mimeType)
            }.value
            guard let imageType else {
                warnings.append(.invalidImage)
                continue
            }
            let destination = root.appending(path: "image-\(localURLs.count).\(imageType.fileExtension)")
            guard destination.standardizedFileURL.deletingLastPathComponent() == root,
                  FileManager.default.fileExists(atPath: destination.path) == false,
                  Self.isSafeDirectory(root)
            else {
                warnings.append(.unsafeDestination)
                continue
            }
            do {
                let temporary = root.appending(path: ".image-\(UUID().uuidString).partial")
                try response.data.write(to: temporary, options: .withoutOverwriting)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard temporary.standardizedFileURL.deletingLastPathComponent() == root,
                      destination.standardizedFileURL.deletingLastPathComponent() == root,
                      Self.isSafeDirectory(root),
                      FileManager.default.fileExists(atPath: destination.path) == false
                else { throw CocoaError(.fileWriteFileExists) }
                try FileManager.default.moveItem(at: temporary, to: destination)
                localURLs.append(destination)
                totalBytes += response.data.count
            } catch {
                warnings.append(.unsafeDestination)
            }
        }
        return ArticleImageLocalization(localURLs: localURLs, warnings: warnings)
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func warning(for error: ArticleBoundedURLLoader.Error) -> ArticleImageLocalizationWarning {
        switch error {
        case .unsupportedURL: .invalidURL
        case .unsupportedContentType: .invalidContentType
        case .responseTooLarge: .responseTooLarge
        case .tooManyRedirects, .invalidHTTPResponse, .cancelled, .transport: .downloadFailed
        }
    }

    private nonisolated static func validatedImageType(data: Data, mimeType: String) -> ArticleImageType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?
        else { return nil }
        let imageType: ArticleImageType
        switch (mimeType, type) {
        case ("image/jpeg", "public.jpeg"):
            guard data.starts(with: [0xFF, 0xD8]), data.suffix(2) == Data([0xFF, 0xD9]) else { return nil }
            imageType = .jpeg
        case ("image/png", "public.png"):
            guard PNGIntegrity.isValid(data) else { return nil }
            imageType = .png
        default: return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384
        else { return nil }
        let product = width.multipliedReportingOverflow(by: height)
        guard product.overflow == false, product.partialValue <= 100_000_000 else { return nil }
        let rasterOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, rasterOptions as CFDictionary),
              let context = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return imageType
    }
}

private nonisolated enum PNGIntegrity {
    static func isValid(_ data: Data) -> Bool {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
        let bytes = [UInt8](data)
        var offset = 8
        var sawIHDR = false
        var sawIDAT = false
        var finishedIDATSequence = false
        var header: Header?
        var compressedImageData = Data()
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { return false }
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let typeStart = offset + 4
            let dataStart = offset + 8
            let crcStart = dataStart + length
            guard length >= 0, crcStart + 4 <= bytes.count else { return false }
            let type = String(bytes: bytes[typeStart..<(typeStart + 4)], encoding: .ascii) ?? ""
            guard crc32(bytes[typeStart..<crcStart]) == readUInt32(bytes, at: crcStart) else { return false }
            if type == "IHDR" {
                guard !sawIHDR, offset == 8, length == 13,
                      let parsedHeader = Header(bytes: bytes[dataStart..<crcStart])
                else { return false }
                sawIHDR = true
                header = parsedHeader
            }
            if type == "IDAT" {
                guard sawIHDR, finishedIDATSequence == false else { return false }
                sawIDAT = true
                compressedImageData.append(contentsOf: bytes[dataStart..<crcStart])
            } else if sawIDAT, type != "IEND" {
                finishedIDATSequence = true
            }
            if type == "IEND" {
                return sawIHDR && sawIDAT && length == 0 && crcStart + 4 == bytes.count
                    && header.map { validatesCompressedPixels(compressedImageData, header: $0) } == true
            }
            offset = crcStart + 4
        }
        return false
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    private static func validatesCompressedPixels(_ compressed: Data, header: Header) -> Bool {
        guard header.compressionMethod == 0,
              header.filterMethod == 0,
              header.interlaceMethod == 0,
              let channels = header.channels,
              [1, 2, 4, 8, 16].contains(header.bitDepth)
        else { return false }
        let bitsPerRow = header.width.multipliedReportingOverflow(by: channels)
        guard bitsPerRow.overflow == false else { return false }
        let bits = bitsPerRow.partialValue.multipliedReportingOverflow(by: header.bitDepth)
        guard bits.overflow == false else { return false }
        let rowBytes = (bits.partialValue + 7) / 8
        let rowWithFilter = rowBytes.addingReportingOverflow(1)
        guard rowWithFilter.overflow == false else { return false }
        let expected = rowWithFilter.partialValue.multipliedReportingOverflow(by: header.height)
        guard expected.overflow == false,
              expected.partialValue > 0,
              expected.partialValue <= 100_000_000
        else { return false }
        return hasCompleteZlibStream(compressed, expectedOutputBytes: expected.partialValue)
    }

    private static func hasCompleteZlibStream(_ compressed: Data, expectedOutputBytes: Int) -> Bool {
        guard compressed.isEmpty == false else { return false }
        return compressed.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer(mutating: source)
            stream.avail_in = uInt(sourceBuffer.count)
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
            defer { inflateEnd(&stream) }
            var totalOutput = 0
            while true {
                var output = [UInt8](repeating: 0, count: 8 * 1024)
                let status: Int32 = output.withUnsafeMutableBytes { destinationBuffer in
                    stream.next_out = destinationBuffer.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(destinationBuffer.count)
                    return inflate(&stream, Z_FINISH)
                }
                let emitted = output.count - Int(stream.avail_out)
                let total = totalOutput.addingReportingOverflow(emitted)
                guard total.overflow == false, total.partialValue <= expectedOutputBytes else { return false }
                totalOutput = total.partialValue
                if status == Z_STREAM_END {
                    return stream.avail_in == 0 && totalOutput == expectedOutputBytes
                }
                guard status == Z_OK, emitted > 0 else { return false }
            }
        }
    }

    private struct Header {
        let width: Int
        let height: Int
        let bitDepth: Int
        let colorType: UInt8
        let compressionMethod: UInt8
        let filterMethod: UInt8
        let interlaceMethod: UInt8

        init?(bytes: ArraySlice<UInt8>) {
            guard bytes.count == 13 else { return nil }
            let values = Array(bytes)
            let width = Int(readUInt32(values, at: 0))
            let height = Int(readUInt32(values, at: 4))
            guard width > 0, height > 0 else { return nil }
            self.width = width
            self.height = height
            self.bitDepth = Int(values[8])
            self.colorType = values[9]
            self.compressionMethod = values[10]
            self.filterMethod = values[11]
            self.interlaceMethod = values[12]
        }

        var channels: Int? {
            switch colorType {
            case 0, 3: 1
            case 2: 3
            case 4: 2
            case 6: 4
            default: nil
            }
        }
    }
}
