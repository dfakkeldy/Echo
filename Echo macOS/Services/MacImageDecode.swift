// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// Off-main image decoding for the Mac app. Returns CGImage (Sendable) so
/// callers hop back to the main actor and wrap in NSImage there — decoding
/// multi-MB covers/photos on the main thread was audit fix 5.
nonisolated enum MacImageDecode {
    /// Decodes `data` to a downsampled CGImage (long edge ≤ maxPixelSize).
    static func downsampledCGImage(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Reads and decodes `url` off the caller's actor.
    static func loadCGImage(url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return downsampledCGImage(data: data, maxPixelSize: maxPixelSize)
    }
}
