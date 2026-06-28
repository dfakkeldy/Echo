// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct SettingsHelpPathTests {
    @Test func helpContentUsesCurrentSettingsPaths() throws {
        let source = try Self.source("EchoCore/Views/HelpContent.swift")

        #expect(source.contains("Settings > Controls > Phone Player Settings"))
        #expect(source.contains("Settings > Now Playing > Playback Defaults"))
        #expect(source.contains("Settings > Now Playing > Playback Defaults > Smart Rewind"))
        #expect(source.contains("Settings > Controls > Watch App Settings"))
        #expect(!source.contains("Settings > Phone Controls"))
        #expect(!source.contains("Settings > Playback > Default Speed"))
        #expect(!source.contains("Settings > Smart Rewind"))
        #expect(!source.contains("Settings > Watch App"))
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
