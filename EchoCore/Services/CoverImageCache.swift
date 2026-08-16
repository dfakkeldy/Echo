// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// Decodes a library cover once and remembers it, for every target that
/// compiles `EchoCore` — the iOS app, the Mac app, and `echo-cli`.
///
/// This is a new file rather than a method on `ArtworkCache` because
/// `ArtworkCache` cannot be shared: it is typed in `UIImage` and it is listed
/// in the `Echo macOS` and `echo-cli` membership exceptions, so the Mac cannot
/// call it without a pbxproj membership change. Everything here is ImageIO and
/// CoreGraphics, which both platforms have, so this file needs no exception
/// entry and contains no `#if` at all — callers wrap the returned `CGImage` in
/// whichever platform image they render with. That is also why it must not
/// reach for `MacImageDecode`: `echo-cli` builds against the macOS SDK but does
/// not compile the `Echo macOS` folder, so an `#if os(macOS)` reference to it
/// would break the CLI.
///
/// Despite the old name, `ArtworkCache` never memoized anything but the Watch
/// transfer JPEG; both platforms re-read and re-decoded a cover every time a
/// cell appeared. This type is the memo that was missing.
///
/// `@concurrent` (not plain `nonisolated async`) is what actually moves the
/// decode off the caller's actor: this project builds with
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES`, under which a plain `nonisolated
/// async` called from a `@MainActor` `.task` runs ON the main thread. Do not
/// drop the attribute.
nonisolated enum CoverImageCache {

    /// Long-edge cap for a decoded cover, matching `ArtworkCache.loadImageFile`
    /// so the same file resolves to the same pixels on either platform.
    static let defaultMaxPixelSize = 600

    /// Roughly 32 MB of decoded pixels — about twenty 600×600 covers. A
    /// scrolling shelf only needs the covers near the viewport, and every entry
    /// is pure derived data that costs one decode to rebuild, so a bounded
    /// budget is preferable to a map that grows with the size of the library.
    static let byteBudget = 32 * 1024 * 1024

    /// Identity of a cached cover. Covers live in the *caches* directory and
    /// are rewritten in place by library enrichment and ABS import, so a path
    /// alone is not an identity: including the modification date and size means
    /// a replaced cover misses and re-decodes instead of serving stale art.
    struct Key: Hashable, Sendable {
        let path: String
        let modified: Date?
        let size: Int?

        init(url: URL) {
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey,
            ])
            path = url.path(percentEncoded: false)
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    struct Entry {
        let image: CGImage
        /// Decoded footprint, which is what the budget is spent on — the
        /// on-disk file size says nothing about how much RAM the pixels take.
        let bytes: Int
    }

    /// The bounded LRU behind `image(at:)`, kept as a plain value type rather
    /// than inlined into the lock's closures so eviction can be exercised
    /// directly instead of by decoding 32 MB of real covers.
    struct Store {
        let byteBudget: Int
        private(set) var entries: [Key: Entry] = [:]
        /// Least-recently-used first.
        private(set) var order: [Key] = []
        private(set) var bytes = 0

        init(byteBudget: Int = CoverImageCache.byteBudget) {
            self.byteBudget = byteBudget
        }

        mutating func value(for key: Key) -> CGImage? {
            guard let entry = entries[key] else { return nil }
            if let index = order.firstIndex(of: key) {
                order.append(order.remove(at: index))
            }
            return entry.image
        }

        mutating func insert(_ image: CGImage, for key: Key) {
            if let existing = entries.removeValue(forKey: key) {
                bytes -= existing.bytes
                order.removeAll { $0 == key }
            }
            let entry = Entry(image: image, bytes: image.height * image.bytesPerRow)
            entries[key] = entry
            order.append(key)
            bytes += entry.bytes

            // Never evict the entry just inserted: a single cover larger than
            // the whole budget should still be usable by the cell that asked
            // for it, rather than being dropped and re-decoded forever.
            while bytes > byteBudget, order.count > 1 {
                let oldest = order.removeFirst()
                bytes -= entries.removeValue(forKey: oldest)?.bytes ?? 0
            }
        }
    }

    private static let store = Mutex(Store())

    /// Returns the downsampled cover at `url`, decoding only on a miss.
    ///
    /// The lock is never held across the decode, so two cells that miss on the
    /// same cover at the same moment may both decode it. That duplicate is far
    /// cheaper than serializing every cover decode in the shelf behind one
    /// lock, and the second insert simply replaces the first.
    @concurrent
    static func image(at url: URL, maxPixelSize: Int = defaultMaxPixelSize) async -> CGImage? {
        #if DEBUG
            let isMainThread = Self.debugIsMainThread()
            Self.debugImageRanOnMainThread.withLock { $0 = isMainThread }
        #endif

        let key = Key(url: url)
        if let cached = store.withLock({ $0.value(for: key) }) { return cached }
        guard let decoded = decode(at: url, maxPixelSize: maxPixelSize) else { return nil }
        store.withLock { $0.insert(decoded, for: key) }
        return decoded
    }

    /// The single downsampling implementation both platforms use — the Mac
    /// reaches it through `image(at:)`, iOS additionally through
    /// `ArtworkCache.loadImageFile`, so a cover cannot drift between them.
    /// Synchronous and uncached on purpose: callers that already own an
    /// off-main context (and folder scans that should not be memoized) use it
    /// directly.
    static func decode(at url: URL, maxPixelSize: Int = defaultMaxPixelSize) -> CGImage? {
        #if DEBUG
            Self.debugDecodeCount.withLock { $0 += 1 }
        #endif

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Drops every cached cover. Entries are pure derived data, so this is
    /// always safe; tests use it to start from a known state.
    static func removeAll() {
        store.withLock { $0 = Store() }
    }

    #if DEBUG
        /// Test-only: how many times `decode` actually read and decoded a file.
        /// A hit and a miss return an equivalent image, so this counter is the
        /// only direct evidence that the memo is doing anything.
        static let debugDecodeCount = Mutex(0)
        /// Test-only: whether the most recent `image(at:)` body ran on the main
        /// thread. Mirrors `MacImageDecode.debugLoadCGImageRanOnMainThread` so
        /// the off-main guarantee is measured rather than trusted from the
        /// `@concurrent` annotation alone. Not compiled into release builds.
        static let debugImageRanOnMainThread = Mutex<Bool?>(nil)
        /// `Thread.isMainThread` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — reading
        /// it directly inside an `async` body does not compile. This
        /// synchronous wrapper is the sanctioned way to read it from async code.
        private static func debugIsMainThread() -> Bool { Thread.isMainThread }
    #endif
}
