// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO

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
            guard let imageType = Self.validatedImageType(data: response.data, mimeType: response.mimeType) else {
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

    private enum ImageType {
        case jpeg
        case png

        var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    }

    private static func validatedImageType(data: Data, mimeType: String) -> ImageType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?
        else { return nil }
        let imageType: ImageType
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
            kCGImageSourceThumbnailMaxPixelSize: 16_384,
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
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { return false }
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let typeStart = offset + 4
            let dataStart = offset + 8
            let crcStart = dataStart + length
            guard length >= 0, crcStart + 4 <= bytes.count else { return false }
            let type = String(bytes: bytes[typeStart..<(typeStart + 4)], encoding: .ascii) ?? ""
            guard crc32(bytes[typeStart..<crcStart]) == readUInt32(bytes, at: crcStart) else { return false }
            if type == "IHDR" { guard !sawIHDR, offset == 8, length == 13 else { return false }; sawIHDR = true }
            if type == "IDAT" { guard sawIHDR else { return false }; sawIDAT = true }
            if type == "IEND" { return sawIHDR && sawIDAT && length == 0 && crcStart + 4 == bytes.count }
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
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
