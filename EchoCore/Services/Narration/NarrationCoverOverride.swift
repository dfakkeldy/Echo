// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ImageIO

nonisolated enum NarrationCoverOverride {
    static let maximumEncodedBytes = 32 * 1024 * 1024
    static let maximumDimension = 8_192

    static func load(from url: URL) throws -> Data {
        guard url.isFileURL else {
            throw ValidationError("cover must be a local file")
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ValidationError("cover must be an existing non-symlink file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_size > 0,
            status.st_size <= maximumEncodedBytes
        else {
            throw ValidationError("cover must be a nonempty regular file no larger than 32 MB")
        }

        let data = try handle.read(upToCount: maximumEncodedBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumEncodedBytes,
            isPNG(data) || isJPEG(data),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0,
            width == height,
            width <= maximumDimension,
            height <= maximumDimension,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw ValidationError(
                "cover must be a decodable square PNG or JPEG no larger than 8192 × 8192 pixels")
        }
        return data
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    struct ValidationError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
