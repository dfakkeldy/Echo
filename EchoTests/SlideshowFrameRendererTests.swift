// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing

@testable import Echo

struct SlideshowFrameRendererTests {
    private func frame(
        subtitle: String? = "Hello world of tests",
        activeWord: Int? = nil, heard: Int = 0, imagePath: String? = nil,
        caption: String? = "A caption"
    ) -> SlideshowFramePlan {
        SlideshowFramePlan(
            startTime: 0, duration: 1,
            visualContent: imagePath.map { .image(path: $0) }, caption: caption,
            subtitleText: subtitle, activeWordIndex: activeWord,
            alreadyHeardWordCount: heard)
    }

    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.height * context.bytesPerRow)
    }

    @Test func rendersFrameAtRequestedSize() {
        let renderer = SlideshowFrameRenderer(width: 640, height: 360, coverArt: nil)
        let image = renderer.render(frame())
        #expect(image?.width == 640)
        #expect(image?.height == 360)
    }

    @Test func renderedFrameIsNotBlank() throws {
        let renderer = SlideshowFrameRenderer(width: 320, height: 180, coverArt: nil)
        let image = try #require(renderer.render(frame()))
        let distinct = Set(pixels(image))
        #expect(distinct.count > 2)  // background + at least one text shade
    }

    @Test func activeWordChangesThePixels() throws {
        let renderer = SlideshowFrameRenderer(width: 320, height: 180, coverArt: nil)
        let a = try #require(renderer.render(frame(activeWord: 0, heard: 0)))
        let b = try #require(renderer.render(frame(activeWord: 2, heard: 0)))
        #expect(pixels(a) != pixels(b))
    }

    @Test func heardWordWashChangesThePixels() throws {
        let renderer = SlideshowFrameRenderer(width: 320, height: 180, coverArt: nil)
        let a = try #require(renderer.render(frame(activeWord: nil, heard: 0)))
        let b = try #require(renderer.render(frame(activeWord: nil, heard: 2)))
        #expect(pixels(a) != pixels(b))
    }

    @Test func missingImagePathFallsBackToCoverArtWithoutFailing() throws {
        let cover = try #require(Self.solidImage(width: 4, height: 4))
        let withCover = SlideshowFrameRenderer(width: 320, height: 180, coverArt: cover)
        let withoutCover = SlideshowFrameRenderer(width: 320, height: 180, coverArt: nil)
        let missingFrame = frame(
            subtitle: nil, imagePath: "/nowhere/gone-book/x.jpg", caption: nil)
        let fallback = try #require(withCover.render(missingFrame))
        let blank = try #require(withoutCover.render(missingFrame))
        #expect(pixels(fallback) != pixels(blank))
    }

    @Test func reusesBaseFrameWhenOnlySubtitleStateChanges() throws {
        let figure = try #require(Self.solidImage(width: 40, height: 40))
        let loadCount = Mutex(0)
        let renderer = SlideshowFrameRenderer(
            width: 320,
            height: 180,
            coverArt: nil,
            imageLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return figure
            })

        let first = try #require(
            renderer.render(
                frame(
                    subtitle: "First subtitle state",
                    activeWord: 0,
                    heard: 0,
                    imagePath: "/fixture/same-image.png",
                    caption: "Same caption")))
        let second = try #require(
            renderer.render(
                frame(
                    subtitle: "Second subtitle state",
                    activeWord: 1,
                    heard: 1,
                    imagePath: "/fixture/same-image.png",
                    caption: "Same caption")))

        #expect(pixels(first) != pixels(second))
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test func appliesRotatedAndMirroredImageOrientationMetadata() throws {
        let source = try #require(Self.splitImage(width: 40, height: 100))
        let uprightURL = try Self.orientedTIFF(source, orientation: 1)
        let rotatedURL = try Self.orientedTIFF(source, orientation: 6)
        let mirroredURL = try Self.orientedTIFF(source, orientation: 7)
        defer {
            try? FileManager.default.removeItem(at: uprightURL)
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.removeItem(at: mirroredURL)
        }

        let renderer = SlideshowFrameRenderer(width: 200, height: 200, coverArt: nil)
        let upright = try #require(
            renderer.render(
                frame(subtitle: nil, imagePath: uprightURL.path, caption: nil)))
        let rotated = try #require(
            renderer.render(
                frame(subtitle: nil, imagePath: rotatedURL.path, caption: nil)))
        let mirrored = try #require(
            renderer.render(
                frame(subtitle: nil, imagePath: mirroredURL.path, caption: nil)))

        // Orientations 1 and 6 differ by a quarter turn; identical output means
        // the rotation metadata was ignored.
        #expect(pixels(upright) != pixels(rotated))
        // Orientations 6 and 7 differ only by mirroring; identical output means
        // the metadata was ignored.
        #expect(pixels(rotated) != pixels(mirrored))
    }

    private static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.2, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private static func splitImage(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()
    }

    private static func orientedTIFF(
        _ image: CGImage, orientation: UInt32
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).tiff")
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, "public.tiff" as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }
}
