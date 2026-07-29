// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO

nonisolated enum ArticleImageLocalizationWarning: Equatable, Sendable {
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

    init(sessionConfiguration: URLSessionConfiguration = ArticleURLCaptureService.ephemeralConfiguration()) {
        self.sessionConfiguration = sessionConfiguration
    }

    func localize(candidates: [URL], into captureDirectory: URL) async -> ArticleImageLocalization {
        let root = captureDirectory.standardizedFileURL
        guard Self.isSafeDirectory(root) else {
            return ArticleImageLocalization(localURLs: [], warnings: [.unsafeDestination])
        }
        var localURLs: [URL] = []
        var warnings: [ArticleImageLocalizationWarning] = []
        var totalBytes = 0

        for candidate in candidates where localURLs.count < ArticleWorkshopLimits.maxImages {
            guard let url = ArticleNetworkURLPolicy.normalized(candidate) else {
                warnings.append(.invalidURL)
                continue
            }
            let loader = ArticleBoundedURLLoader(
                configuration: sessionConfiguration,
                acceptedMIMETypes: ["image/jpeg", "image/png"],
                maximumBytes: ArticleWorkshopLimits.maxSingleImageBytes)
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
            guard totalBytes <= ArticleWorkshopLimits.maxTotalImageBytes - response.data.count else {
                warnings.append(.totalByteLimitReached)
                continue
            }
            guard let imageType = Self.validatedImageType(data: response.data, mimeType: response.mimeType) else {
                warnings.append(.invalidImage)
                continue
            }
            let destination = root.appending(path: "image-\(localURLs.count).\(imageType.fileExtension)")
            guard destination.standardizedFileURL.deletingLastPathComponent() == root,
                  FileManager.default.fileExists(atPath: destination.path) == false
            else {
                warnings.append(.unsafeDestination)
                continue
            }
            do {
                try response.data.write(to: destination, options: .atomic)
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
              let type = CGImageSourceGetType(source) as String?
        else { return nil }
        let imageType: ImageType
        switch (mimeType, type) {
        case ("image/jpeg", "public.jpeg"): imageType = .jpeg
        case ("image/png", "public.png"): imageType = .png
        default: return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384
        else { return nil }
        let product = width.multipliedReportingOverflow(by: height)
        guard product.overflow == false, product.partialValue <= 100_000_000 else { return nil }
        return imageType
    }
}
