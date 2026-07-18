// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Testing

@testable import Echo

struct SlideshowFrameRendererTests {
    private func frame(
        subtitle: String? = "Hello world of tests",
        activeWord: Int? = nil, heard: Int = 0, imagePath: String? = nil
    ) -> SlideshowFramePlan {
        SlideshowFramePlan(
            startTime: 0, duration: 1, imagePath: imagePath, caption: "A caption",
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
        let b = try #require(renderer.render(frame(activeWord: 2, heard: 2)))
        #expect(pixels(a) != pixels(b))
    }

    @Test func missingImagePathFallsBackToCoverArtWithoutFailing() throws {
        let cover = try #require(Self.solidImage(width: 4, height: 4))
        let renderer = SlideshowFrameRenderer(width: 320, height: 180, coverArt: cover)
        let withMissing = renderer.render(frame(imagePath: "/nowhere/gone-book/x.jpg"))
        #expect(withMissing != nil)
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
}
