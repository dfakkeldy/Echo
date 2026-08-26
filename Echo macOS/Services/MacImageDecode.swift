// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

#if DEBUG
    import Synchronization
#endif

/// Off-main image decoding for the Mac app. `@concurrent` (not plain
/// `nonisolated async`) is what actually leaves the caller's actor: this
/// project builds with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which enables
/// `NonisolatedNonsendingByDefault` — under that mode a plain `nonisolated
/// async` function called from a `@MainActor` context runs ON the main
/// thread, not off it. Do not drop `@concurrent` under the assumption that
/// `nonisolated async` alone suspends off-main; it does not, here. Returns
/// CGImage (Sendable) so callers hop back to the main actor and wrap in
/// NSImage there — decoding multi-MB covers/photos on the main thread was
/// audit fix 5.
nonisolated enum MacImageDecode {
    #if DEBUG
        /// Test/harness-only observation seam: records whether the most recent
        /// `loadCGImage` call executed its body on the main thread. Mutex-protected
        /// (not `nonisolated(unsafe)`) because callers can run concurrently — e.g.
        /// multiple bookmark thumbnails decode in parallel `.task(id:)` closures.
        /// Exists so the off-main guarantee is verified empirically instead of
        /// trusted from the `@concurrent` annotation alone. Not compiled into
        /// release builds.
        nonisolated static let debugLoadCGImageRanOnMainThread = Mutex<Bool?>(nil)
        /// `Thread.isMainThread` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — reading it
        /// directly inside an `async` function body doesn't compile. This
        /// synchronous wrapper is the sanctioned way to read it from async code.
        nonisolated private static func debugIsMainThread() -> Bool { Thread.isMainThread }
    #endif

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

    /// Reads and decodes `url` off the main actor. See the type's doc comment:
    /// `@concurrent` is what makes that true under this project's
    /// `SWIFT_APPROACHABLE_CONCURRENCY` build setting.
    @concurrent
    static func loadCGImage(url: URL, maxPixelSize: Int) async -> CGImage? {
        #if DEBUG
            let isMainThread = Self.debugIsMainThread()
            Self.debugLoadCGImageRanOnMainThread.withLock { $0 = isMainThread }
        #endif
        guard let data = try? Data(contentsOf: url) else { return nil }
        return downsampledCGImage(data: data, maxPixelSize: maxPixelSize)
    }
}
