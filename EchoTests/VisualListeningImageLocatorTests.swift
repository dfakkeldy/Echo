// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Echo

struct VisualListeningImageLocatorTests {
    @Test func returnsStoredPathWhenFileExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("figure.jpg")
        try Data([0xFF]).write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(VisualListeningImageLocator.resolvedURL(forStoredPath: file.path) == file)
    }

    @Test func fallsBackToEPUBAssetsContainerForStalePath() throws {
        let containerName = "locator-test-\(UUID().uuidString)"
        let assetsDir = URL.applicationSupportDirectory
            .appendingPathComponent("EPUBAssets")
            .appendingPathComponent(containerName)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let real = assetsDir.appendingPathComponent("figure.png")
        try Self.writeImage(to: real, width: 9, height: 7)
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let stale = "/old/container/\(containerName)/figure.png"
        let recovered = try #require(
            VisualListeningImageLocator.resolvedURL(forStoredPath: stale))
        #expect(recovered.standardizedFileURL == real.standardizedFileURL)

        let source = try #require(CGImageSourceCreateWithURL(recovered as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 9)
        #expect(image.height == 7)
    }

    @Test func returnsNilWhenNothingExists() {
        #expect(
            VisualListeningImageLocator.resolvedURL(
                forStoredPath: "/nowhere/never-book/missing.jpg") == nil)
    }

    private static func writeImage(to url: URL, width: Int, height: Int) throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}
