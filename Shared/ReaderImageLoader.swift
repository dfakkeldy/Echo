// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO

/// Bounded, shared figure thumbnails. Failed decodes are never cached.
actor ReaderImageLoader {
    static let shared = ReaderImageLoader()
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private var cachedBytes = 0
    private let byteLimit = 32 * 1024 * 1024

    func image(storedPath: String, maxPixelSize: Int = 1600) async -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        let key = "\(maxPixelSize):\(storedPath)"
        if let image = cache[key] { return image }
        guard let image = await Self.decode(storedPath: storedPath, maxPixelSize: maxPixelSize) else { return nil }
        if cache[key] != nil { return cache[key] }
        let bytes = image.bytesPerRow * image.height
        guard bytes <= byteLimit else { return image }
        while cachedBytes + bytes > byteLimit, !order.isEmpty {
            let oldest = order.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cachedBytes -= removed.bytesPerRow * removed.height }
        }
        cache[key] = image
        order.append(key)
        cachedBytes += bytes
        return image
    }

    @concurrent
    private static func decode(storedPath: String, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled,
            let url = VisualListeningImageLocator.resolvedURL(forStoredPath: storedPath),
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}
