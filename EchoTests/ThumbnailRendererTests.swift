// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import UIKit

@testable import Echo

/// Verifies that `ThumbnailRenderer` produces square thumbnails that PRESERVE a
/// cover's aspect ratio — the bug being fixed is portrait covers squished into
/// squares. Fixtures are deliberately asymmetric (1:3 / 3:1) so any width/height
/// distortion is detectable, and pixel probes confirm the cover is fitted and
/// centred with a filled (never transparent, never cropped-away) background.
@MainActor
@Suite struct ThumbnailRendererTests {

    // MARK: - Fixtures & probes

    /// A solid-colour `width`×`height` image at scale 1 (so points == pixels).
    private func solidImage(_ width: Int, _ height: Int, _ color: UIColor) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private struct Pixel { let r: Int, g: Int, b: Int, a: Int }

    /// Reads the RGBA pixel at (`x`, `y`) in the image's pixel grid.
    private func pixel(_ image: UIImage, x: Int, y: Int) -> Pixel {
        let cgImage = image.cgImage!
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let i = (y * width + x) * 4
        return Pixel(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]), a: Int(data[i + 3]))
    }

    // MARK: - Geometry: aspect preservation & centring

    @Test func portraitFitPreservesAspectAndCentresHorizontally() {
        let rect = ThumbnailRenderer.aspectFitRect(
            sourceSize: CGSize(width: 60, height: 180),
            canvasSize: CGSize(width: 300, height: 300))
        #expect(rect.width == 100)  // 1:3 preserved (NOT squished to 300×300)
        #expect(rect.height == 300)
        #expect(rect.minX == 100)  // centred: equal left/right margins
        #expect(rect.minY == 0)
    }

    @Test func landscapeFitPreservesAspectAndCentresVertically() {
        let rect = ThumbnailRenderer.aspectFitRect(
            sourceSize: CGSize(width: 180, height: 60),
            canvasSize: CGSize(width: 300, height: 300))
        #expect(rect.width == 300)
        #expect(rect.height == 100)  // 3:1 preserved
        #expect(rect.minX == 0)
        #expect(rect.minY == 100)  // centred: equal top/bottom margins
    }

    @Test func squareFitFillsCanvasExactly() {
        let rect = ThumbnailRenderer.aspectFitRect(
            sourceSize: CGSize(width: 200, height: 200),
            canvasSize: CGSize(width: 300, height: 300))
        #expect(rect == CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    @Test func degenerateSourceReturnsZeroRect() {
        #expect(
            ThumbnailRenderer.aspectFitRect(
                sourceSize: CGSize(width: 0, height: 100),
                canvasSize: CGSize(width: 300, height: 300)) == .zero)
        #expect(
            ThumbnailRenderer.aspectFitRect(
                sourceSize: CGSize(width: 60, height: 180),
                canvasSize: .zero) == .zero)
    }

    @Test func portraitFillCoversWholeCanvas() {
        let rect = ThumbnailRenderer.aspectFillRect(
            sourceSize: CGSize(width: 60, height: 180),
            canvasSize: CGSize(width: 300, height: 300))
        #expect(rect.minX <= 0)
        #expect(rect.minY <= 0)
        #expect(rect.maxX >= 300)
        #expect(rect.maxY >= 300)
        // Aspect still preserved. Tolerance, not ==: the literal ratio is
        // constant-folded at a different precision than the runtime division.
        #expect(abs(rect.width / rect.height - 60.0 / 180.0) < 0.0001)
    }

    // MARK: - Average colour (tonal base)

    @Test func averageColorOfSolidImageMatchesThatColor() {
        let red = solidImage(64, 64, .red)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ThumbnailRenderer.averageColor(of: red).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r > 0.95)
        #expect(g < 0.05)
        #expect(b < 0.05)
        #expect(a == 1)
    }

    // MARK: - Rendered output: canvas dimensions

    @Test func squareThumbnailHasExactCanvasDimensionsAndScale() {
        let portrait = solidImage(60, 180, .red)
        let thumb = ThumbnailRenderer.squareThumbnail(from: portrait, side: 300, scale: 2)
        #expect(thumb.size == CGSize(width: 300, height: 300))  // points, square
        #expect(thumb.scale == 2)
        #expect(thumb.cgImage?.width == 600)  // pixels = side × scale
        #expect(thumb.cgImage?.height == 600)
    }

    // MARK: - Rendered output: aspect preserved, centred, background filled

    @Test func portraitThumbnailFitsCoverAndFillsSideMarginsWithoutStretching() {
        // Bright-white portrait cover: the fitted cover reads near-white; the
        // side margins are the (scrimmed) background — clearly darker. A squished
        // (stretched) render would make the margins white too, so this asserts
        // BOTH "no stretch" and "background filled, not cropped away".
        let cover = solidImage(60, 180, .white)
        let thumb = ThumbnailRenderer.squareThumbnail(from: cover, side: 300, scale: 1)

        let centre = pixel(thumb, x: 150, y: 150)
        #expect(centre.r >= 245 && centre.g >= 245 && centre.b >= 245)  // cover, centred

        let leftMargin = pixel(thumb, x: 4, y: 150)
        #expect(leftMargin.a == 255)  // background is opaque (never transparent)
        #expect(leftMargin.r <= 235)  // background darker than the white cover
        #expect(centre.r > leftMargin.r + 15)  // pillarbox present -> not stretched
    }

    @Test func landscapeThumbnailFitsCoverAndFillsTopBottomMargins() {
        let cover = solidImage(180, 60, .white)
        let thumb = ThumbnailRenderer.squareThumbnail(from: cover, side: 300, scale: 1)

        let centre = pixel(thumb, x: 150, y: 150)
        #expect(centre.r >= 245)

        let topMargin = pixel(thumb, x: 150, y: 4)
        #expect(topMargin.a == 255)
        #expect(topMargin.r <= 235)
        #expect(centre.r > topMargin.r + 15)  // letterbox present -> not stretched
    }

    @Test func squareCoverFillsCanvasWithNoLetterbox() {
        let cover = solidImage(200, 200, .white)
        let thumb = ThumbnailRenderer.squareThumbnail(from: cover, side: 300, scale: 1)
        // A square cover fits the whole canvas, so even a near-corner probe is the
        // cover (no dark margins).
        let corner = pixel(thumb, x: 4, y: 4)
        let centre = pixel(thumb, x: 150, y: 150)
        #expect(corner.r >= 245)
        #expect(centre.r >= 245)
    }

    // MARK: - Deterministic background

    @Test func renderingIsDeterministic() {
        let cover = solidImage(60, 180, UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        let a = ThumbnailRenderer.squareThumbnail(from: cover, side: 200, scale: 2)
        let b = ThumbnailRenderer.squareThumbnail(from: cover, side: 200, scale: 2)
        #expect(a.pngData() == b.pngData())
    }
}
