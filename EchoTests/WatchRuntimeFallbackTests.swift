// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchRuntimeFallbackTests {
    @Test func runtimeFallbacksMatchTheNewWatchDefaultContract() throws {
        let watchViewModel = try Self.source("Echo Watch App/Services/WatchViewModel.swift")
        #expect(
            watchViewModel.contains("linearBarMode: String = \"chapter\""),
            "WatchViewModel should default fresh watch progress to chapter progress."
        )
        #expect(
            watchViewModel.contains("circularRingMode: String = \"total\""),
            "WatchViewModel should default fresh watch ring progress to total progress."
        )
        #expect(
            watchViewModel.contains("watchArtworkLayout: String = \"classic\""),
            "WatchViewModel should default fresh watch art to the classic face."
        )
        #expect(
            !watchViewModel.contains("linearBarMode: String = \"total\""),
            "WatchViewModel must not retain the old total fallback for linear progress."
        )
        #expect(
            !watchViewModel.contains("circularRingMode: String = \"chapter\""),
            "WatchViewModel must not retain the old chapter fallback for circular progress."
        )
        #expect(
            !watchViewModel.contains("watchArtworkLayout: String = \"immersive\""),
            "WatchViewModel must not retain the old immersive fallback for watch artwork."
        )

        let contentView = try Self.source("Echo Watch App/Views/ContentView.swift")
        #expect(
            contentView.contains("?? .classic"),
            "ContentView should fall back to the classic watch face when the raw value is invalid."
        )
        #expect(
            !contentView.contains("?? .immersive"),
            "ContentView must not fall back to immersive for invalid artwork layout values."
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        let candidate = try repositoryRoot().appending(path: relativePath)
        return try String(contentsOf: candidate, encoding: .utf8)
    }

    private static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: "Echo.xcodeproj").path)
            {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
