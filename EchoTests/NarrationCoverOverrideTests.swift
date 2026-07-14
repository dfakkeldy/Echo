// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Echo

@Suite struct NarrationCoverOverrideTests {
    private func png(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func loadsAndSnapshotsSquareArtwork() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        let original = try png(width: 32, height: 32)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try NarrationCoverOverride.load(from: url)
        try Data("replacement".utf8).write(to: url)

        #expect(loaded == original)
    }

    @Test func rejectsMissingCorruptAndNonsquareArtwork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.png")
        let corrupt = directory.appendingPathComponent("corrupt.png")
        let nonsquare = directory.appendingPathComponent("nonsquare.png")
        try Data("not an image".utf8).write(to: corrupt)
        try png(width: 32, height: 24).write(to: nonsquare)

        #expect(throws: Error.self) { try NarrationCoverOverride.load(from: missing) }
        #expect(throws: Error.self) { try NarrationCoverOverride.load(from: corrupt) }
        #expect(throws: Error.self) { try NarrationCoverOverride.load(from: nonsquare) }
    }

    @Test func rejectsPNGTruncatedAfterValidHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        let truncated = try png(width: 32, height: 32).prefix(33)
        try Data(truncated).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Error.self) { try NarrationCoverOverride.load(from: url) }
    }

    @Test func rejectsDirectoryAndSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.png")
        let link = directory.appendingPathComponent("link.png")
        try png(width: 16, height: 16).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: Error.self) { try NarrationCoverOverride.load(from: directory) }
        #expect(throws: Error.self) { try NarrationCoverOverride.load(from: link) }
    }
}
