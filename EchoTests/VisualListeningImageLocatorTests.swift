// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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
        let assetsDir = FileLocations.applicationSupportDirectory
            .appendingPathComponent("EPUBAssets")
            .appendingPathComponent("locator-test-book")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let real = assetsDir.appendingPathComponent("figure.jpg")
        try Data([0xFF]).write(to: real)
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let stale = "/old/container/locator-test-book/figure.jpg"
        #expect(
            VisualListeningImageLocator.resolvedURL(forStoredPath: stale)?.lastPathComponent
                == "figure.jpg")
    }

    @Test func returnsNilWhenNothingExists() {
        #expect(
            VisualListeningImageLocator.resolvedURL(
                forStoredPath: "/nowhere/never-book/missing.jpg") == nil)
    }
}
