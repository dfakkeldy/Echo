// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Echo

/// The library shelf used to re-read and re-decode the same cover file every
/// time a cell appeared — on macOS at full size, via `NSImage(contentsOf:)`.
/// These cover the memo that replaced it. `.serialized` because the cache and
/// its debug counters are process-wide statics; no other suite touches them.
@Suite(.serialized)
struct CoverImageCacheTests {

    @Test("a second load of an unchanged cover does not decode again")
    func secondLoadOfUnchangedCoverDoesNotDecodeAgain() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cover.png")
        try Self.writePNG(width: 120, height: 180, to: url)
        CoverImageCache.removeAll()

        let before = CoverImageCache.debugDecodeCount.withLock { $0 }
        let first = try #require(await CoverImageCache.image(at: url))
        let afterFirst = CoverImageCache.debugDecodeCount.withLock { $0 }
        let second = try #require(await CoverImageCache.image(at: url))
        let afterSecond = CoverImageCache.debugDecodeCount.withLock { $0 }

        #expect(afterFirst == before + 1, "the first load must actually decode the file")
        #expect(
            afterSecond == afterFirst,
            "the second load must be served from the cache — this is the regression that made shelf scrolling re-read every cover from disk"
        )
        #expect(first.width == second.width)
        #expect(first.height == second.height)
    }

    @Test("rewriting a cover in place invalidates the cached image")
    func rewritingCoverInPlaceInvalidatesCachedImage() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cover.png")
        try Self.writePNG(width: 120, height: 180, to: url)
        CoverImageCache.removeAll()

        let original = try #require(await CoverImageCache.image(at: url))
        // Library enrichment and ABS import both replace a cover at its
        // existing path, so a path-only key would keep serving the old art.
        try FileManager.default.removeItem(at: url)
        try Self.writePNG(width: 300, height: 100, to: url)
        let replaced = try #require(await CoverImageCache.image(at: url))

        #expect(original.width == 120 && original.height == 180)
        #expect(
            replaced.width == 300 && replaced.height == 100,
            "the key carries the file's modification date and size, so a rewritten cover must miss rather than serve stale art"
        )
    }

    @Test("decoding downsamples to the requested long edge")
    func decodeDownsamplesToRequestedLongEdge() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "large.png")
        try Self.writePNG(width: 1800, height: 1200, to: url)
        CoverImageCache.removeAll()

        let image = try #require(await CoverImageCache.image(at: url))

        #expect(max(image.width, image.height) <= CoverImageCache.defaultMaxPixelSize)
        #expect(
            image.width > image.height,
            "the downsample must preserve the source aspect ratio, not square the cover off")
    }

    @Test("the decode runs off the main actor")
    @MainActor
    func decodeRunsOffTheMainActor() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cover.png")
        try Self.writePNG(width: 120, height: 180, to: url)
        CoverImageCache.removeAll()
        CoverImageCache.debugImageRanOnMainThread.withLock { $0 = nil }

        _ = await CoverImageCache.image(at: url)

        let ranOnMain = CoverImageCache.debugImageRanOnMainThread.withLock { $0 }
        #expect(
            ranOnMain == false,
            "`image(at:)` must stay @concurrent — under this project's SWIFT_APPROACHABLE_CONCURRENCY build setting, a plain `nonisolated async` called from this @MainActor test would run ON the main thread, silently putting cover decoding back on the UI actor."
        )
    }

    @Test("eviction keeps the store under its byte budget")
    func evictionKeepsStoreUnderByteBudget() throws {
        let first = try #require(Self.makeCGImage(width: 40, height: 40))
        let second = try #require(Self.makeCGImage(width: 40, height: 40))
        let third = try #require(Self.makeCGImage(width: 40, height: 40))
        // A budget below one image's footprint, so every insert must evict.
        var store = CoverImageCache.Store(byteBudget: 1)

        store.insert(first, for: Self.key(path: "/a.png"))
        store.insert(second, for: Self.key(path: "/b.png"))
        store.insert(third, for: Self.key(path: "/c.png"))

        // Hoisted rather than called inside `#expect`: the macro decomposes
        // binary expressions and cannot capture a `mutating` call on `store`.
        let newest = store.value(for: Self.key(path: "/c.png"))
        let oldest = store.value(for: Self.key(path: "/a.png"))
        #expect(
            store.entries.count == 1,
            "an unbounded image cache is a leak: the shelf can hold thousands of covers")
        #expect(
            newest != nil,
            "the entry just inserted must survive even when it alone exceeds the budget, or its cell re-decodes forever"
        )
        #expect(oldest == nil)
    }

    @Test("the least recently used entry is evicted first")
    func leastRecentlyUsedEntryIsEvictedFirst() throws {
        let images = try (0..<3).map { _ in try #require(Self.makeCGImage(width: 40, height: 40)) }
        let footprint = images[0].height * images[0].bytesPerRow
        // Room for exactly two covers, so the third insert evicts one.
        var store = CoverImageCache.Store(byteBudget: footprint * 2)
        store.insert(images[0], for: Self.key(path: "/a.png"))
        store.insert(images[1], for: Self.key(path: "/b.png"))

        // Re-reading /a.png makes /b.png the least recently used one.
        _ = store.value(for: Self.key(path: "/a.png"))
        store.insert(images[2], for: Self.key(path: "/c.png"))

        let retained = store.value(for: Self.key(path: "/a.png"))
        let evicted = store.value(for: Self.key(path: "/b.png"))
        #expect(retained != nil)
        #expect(
            evicted == nil,
            "a hit must refresh recency, otherwise scrolling back up evicts the covers still on screen"
        )
    }

    // MARK: - Helpers

    private static func key(path: String) -> CoverImageCache.Key {
        CoverImageCache.Key(url: URL(fileURLWithPath: path))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(
                path: "CoverImageCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeCGImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(gray: 0.5, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        let image = try #require(makeCGImage(width: width, height: height))
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
