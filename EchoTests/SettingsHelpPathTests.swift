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

    @Test func userManualUsesCurrentSettingsPaths() throws {
        let source = try Self.source("docs/guides/user-manual.md")

        #expect(source.contains("Settings → Controls → Phone Player Settings"))
        #expect(source.contains("Settings → Now Playing → Playback Defaults → Smart Rewind"))
        #expect(source.contains("Settings → Advanced & Privacy → Advanced → Context Memory"))
        #expect(source.contains("Settings → Now Playing → Playback Defaults"))
        #expect(source.contains("Settings → Study & Notes"))
        #expect(!source.contains("Settings → Player Controls"))
        #expect(!source.contains("Settings → Smart Rewind"))
        #expect(!source.contains("Settings → Privacy & Location"))
        #expect(!source.contains("Settings → Study —"))
    }

    @Test func htmlManualUsesCurrentSettingsPaths() throws {
        let source = try Self.source("docs/manual.html")

        #expect(source.contains("Settings → Controls → Phone Player Settings"))
        #expect(source.contains("Settings → Now Playing → Playback Defaults → Smart Rewind"))
        #expect(source.contains("Settings → Advanced &amp; Privacy → Advanced → Context Memory"))
        #expect(source.contains("Settings → Now Playing → Playback Defaults"))
        #expect(!source.contains("Settings → Player Controls"))
        #expect(!source.contains("Settings → Smart Rewind"))
        #expect(!source.contains("Settings → Privacy &amp; Location"))
        #expect(!source.contains("Settings → Study —"))
    }

    @Test func architectureMatchesSettingsInformationArchitecture() throws {
        let source = try Self.source("ARCHITECTURE.md")

        #expect(source.contains("Settings > Controls > Phone Player Settings > Layout"))
        #expect(source.contains("SettingsView` is a thin app-level shell organized by user intent"))
        #expect(source.contains("Now Playing, Appearance, Controls, Library & Accounts, Study & Notes, Advanced & Privacy, and Support & About"))
        #expect(source.contains("PlayerMoreMenu` in the `BottomToolbarView` dock holds Chapters"))
        #expect(!source.contains("Sleep-timer submenu, and Settings"))
        #expect(!source.contains("submenu, and Settings"))
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
