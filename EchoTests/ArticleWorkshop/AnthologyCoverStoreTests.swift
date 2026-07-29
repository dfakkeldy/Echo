// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Echo

@Suite(.serialized)
struct AnthologyCoverStoreTests {
    @Test func copiesValidatedImageIntoManagedAnthologyDirectory() throws {
        let fixture = try CoverStoreFixture()
        defer { fixture.removeFiles() }
        let source = fixture.root.appending(path: "chosen.png")
        try fixture.png(width: 2, height: 3).write(to: source)
        let anthologyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let store = AnthologyCoverStore(root: fixture.managedRoot)

        let path = try store.importCover(from: source, anthologyID: anthologyID)

        #expect(path.hasPrefix("cover-"))
        #expect(path.hasSuffix(".png"))
        let managed = fixture.managedRoot
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
            .appending(path: path)
        #expect(FileManager.default.fileExists(atPath: managed.path))
        #expect(try Data(contentsOf: managed) == Data(contentsOf: source))
        #expect(path.contains(source.path) == false)
    }

    @Test func rejectsOversizedMalformedHighDimensionAndSymlinkedInputs() throws {
        let fixture = try CoverStoreFixture()
        defer { fixture.removeFiles() }
        let anthologyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let oversized = fixture.root.appending(path: "oversized.png")
        try Data(repeating: 0, count: 65).write(to: oversized)
        #expect(throws: AnthologyCoverStore.Error.self) {
            _ = try AnthologyCoverStore(
                root: fixture.managedRoot,
                maximumBytes: 64,
                maximumDimension: 8
            )
            .importCover(from: oversized, anthologyID: anthologyID)
        }

        let malformed = fixture.root.appending(path: "malformed.png")
        try Data("not an image".utf8).write(to: malformed)
        #expect(throws: AnthologyCoverStore.Error.self) {
            _ = try AnthologyCoverStore(root: fixture.managedRoot)
                .importCover(from: malformed, anthologyID: anthologyID)
        }

        let largePixels = fixture.root.appending(path: "large.png")
        try fixture.png(width: 9, height: 2).write(to: largePixels)
        #expect(throws: AnthologyCoverStore.Error.self) {
            _ = try AnthologyCoverStore(
                root: fixture.managedRoot,
                maximumBytes: 1_024 * 1_024,
                maximumDimension: 8
            )
            .importCover(from: largePixels, anthologyID: anthologyID)
        }

        let excessiveArea = fixture.root.appending(path: "excessive-area.png")
        try fixture.png(width: 5, height: 5).write(to: excessiveArea)
        #expect(throws: AnthologyCoverStore.Error.dimensionsTooLarge) {
            _ = try AnthologyCoverStore(
                root: fixture.managedRoot,
                maximumBytes: 1_024 * 1_024,
                maximumDimension: 8,
                maximumPixelCount: 20
            )
            .importCover(from: excessiveArea, anthologyID: anthologyID)
        }

        let real = fixture.root.appending(path: "real.png")
        let link = fixture.root.appending(path: "linked.png")
        try fixture.png(width: 2, height: 2).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: AnthologyCoverStore.Error.self) {
            _ = try AnthologyCoverStore(root: fixture.managedRoot)
                .importCover(from: link, anthologyID: anthologyID)
        }
    }

    @Test func rejectsSymlinkedManagedRootBeforeCreatingAnyDestinationDirectory() throws {
        let fixture = try CoverStoreFixture()
        defer { fixture.removeFiles() }
        let source = fixture.root.appending(path: "chosen.png")
        try fixture.png(width: 2, height: 2).write(to: source)
        let outside = fixture.root.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: fixture.managedRoot)
        try FileManager.default.createSymbolicLink(
            at: fixture.managedRoot,
            withDestinationURL: outside)

        #expect(throws: AnthologyCoverStore.Error.unsafeDestination) {
            _ = try AnthologyCoverStore(root: fixture.managedRoot)
                .importCover(
                    from: source,
                    anthologyID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: outside.appending(path: "Anthologies").path) == false)
    }

    @Test func validatesOnlyCanonicalCoverInsideTheMatchingManagedAnthology() throws {
        let fixture = try CoverStoreFixture()
        defer { fixture.removeFiles() }
        let source = fixture.root.appending(path: "chosen.png")
        try fixture.png(width: 2, height: 2).write(to: source)
        let anthologyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let store = AnthologyCoverStore(root: fixture.managedRoot)
        let filename = try store.importCover(from: source, anthologyID: anthologyID)

        #expect(
            try store.validateManagedCover(
                named: filename,
                anthologyID: anthologyID) == filename)
        #expect(throws: AnthologyCoverStore.Error.unsafeDestination) {
            _ = try store.validateManagedCover(
                named: "../cover.png",
                anthologyID: anthologyID)
        }
        #expect(throws: AnthologyCoverStore.Error.unsafeDestination) {
            _ = try store.validateManagedCover(
                named: filename,
                anthologyID: otherID)
        }
    }

    @Test func sameFormatReplacementGetsNewImmutablePathAndPreservesPriorCover() throws {
        let fixture = try CoverStoreFixture()
        defer { fixture.removeFiles() }
        let anthologyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let firstSource = fixture.root.appending(path: "first.png")
        let secondSource = fixture.root.appending(path: "second.png")
        let firstData = try fixture.png(width: 2, height: 2)
        let secondData = try fixture.png(width: 3, height: 3)
        try firstData.write(to: firstSource)
        try secondData.write(to: secondSource)
        let store = AnthologyCoverStore(root: fixture.managedRoot)

        let first = try store.importCover(from: firstSource, anthologyID: anthologyID)
        let second = try store.importCover(from: secondSource, anthologyID: anthologyID)

        #expect(first != second)
        let directory = fixture.managedRoot
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
        #expect(try Data(contentsOf: directory.appending(path: first)) == firstData)
        #expect(try Data(contentsOf: directory.appending(path: second)) == secondData)
        #expect(try store.validateManagedCover(named: first, anthologyID: anthologyID) == first)
        #expect(try store.validateManagedCover(named: second, anthologyID: anthologyID) == second)
    }
}

private struct CoverStoreFixture {
    let root: URL
    let managedRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "AnthologyCoverStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        managedRoot = root.appending(path: "Workshop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: false)
    }

    func png(width: Int, height: Int) throws -> Data {
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
                data,
                UTType.png.identifier as CFString,
                1,
                nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}
