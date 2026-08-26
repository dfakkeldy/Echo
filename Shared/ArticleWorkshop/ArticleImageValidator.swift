// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO

nonisolated enum ArticleImageValidator {
    static func isValid(data: Data, mediaType: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let type = CGImageSourceGetType(source) as String?
        else { return false }

        switch (mediaType, type) {
        case ("image/jpeg", "public.jpeg"):
            guard data.starts(with: [0xFF, 0xD8]),
                data.suffix(2) == Data([0xFF, 0xD9])
            else { return false }
        case ("image/png", "public.png"):
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                return false
            }
        default:
            return false
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 16_384, height <= 16_384
        else { return false }
        let product = width.multipliedReportingOverflow(by: height)
        guard product.overflow == false, product.partialValue <= 100_000_000 else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }
}
