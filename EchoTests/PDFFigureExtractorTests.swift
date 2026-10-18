// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Echo

struct PDFFigureExtractorTests {
    /// Writes a 1-page PDF (612x792) with a 200x200 solid-color image drawn at (100,100).
    private func makeFixturePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil)
        // Build a 200x200 red CGImage.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = try #require(
            CGContext(
                data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bmp.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = try #require(bmp.makeImage())
        ctx.draw(image, in: CGRect(x: 100, y: 100, width: 200, height: 200))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    @Test func extractsOneFigureFromSinglePagePDF() throws {
        let pdf = try makeFixturePDF()
        let figures = PDFFigureExtractor.extractFigures(from: pdf)
        #expect(figures.count == 1)
        let fig = try #require(figures.first)
        #expect(fig.pageIndex == 0)
        #expect(fig.pngData.count > 0)
        // Confirm the PNG decodes.
        let src = try #require(CGImageSourceCreateWithData(fig.pngData as CFData, nil))
        #expect(CGImageSourceGetCount(src) == 1)
    }

    @Test func returnsEmptyForTextOnlyPDF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        #expect(PDFFigureExtractor.extractFigures(from: url).isEmpty)
    }
}
