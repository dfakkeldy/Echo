// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct NavigationDestinationTests {
    private func source() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appending(path: "EchoCore/Models/NavigationDestinations.swift")
            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func audioSettingsRouteUsesRealPlaybackOptionsSurface() throws {
        let src = try source()

        #expect(src.contains("case .settingsAudio:"))
        #expect(src.contains("PlaybackOptionsSheet()"))
        #expect(!src.contains("SettingsPlaceholder(title: \"Audio Settings\")"))
    }
}
