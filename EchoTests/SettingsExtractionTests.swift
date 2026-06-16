// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Verifies that the formerly-private Settings sub-views were extracted into
/// their own files in EchoCore/Views, so NavigationDestinations can reference
/// them and SettingsView stays a thin shell.
struct SettingsExtractionTests {
    @Test func appearanceSubViewIsExtracted() throws {
        let source = try Self.source(named: "SettingsAppearanceView.swift")
        #expect(
            source.contains("struct SettingsAppearanceView"),
            "SettingsAppearanceView must live in its own file."
        )
    }

    @Test func fontSelectionSubViewIsExtracted() throws {
        let source = try Self.source(named: "FontSelectionView.swift")
        #expect(source.contains("struct FontSelectionView"))
    }

    @Test func themeSelectionSubViewIsExtracted() throws {
        let source = try Self.source(named: "ThemeSelectionView.swift")
        #expect(source.contains("struct ThemeSelectionView"))
    }

    @Test func proTranscriptsSubViewIsExtracted() throws {
        let source = try Self.source(named: "ProTranscriptsSettingsView.swift")
        #expect(source.contains("struct ProTranscriptsSettingsView"))
    }

    @Test func appIconSubViewIsExtracted() throws {
        let source = try Self.source(named: "AppIconSelectionView.swift")
        #expect(source.contains("struct AppIconSelectionView"))
    }

    /// `SettingsView` must no longer declare any of the extracted sub-views.
    @Test func settingsViewNoLongerDeclaresExtractedSubViews() throws {
        let source = try Self.source(named: "SettingsView.swift")
        #expect(!source.contains("private struct SettingsAppearanceView"))
        #expect(!source.contains("private struct FontSelectionView"))
        #expect(!source.contains("private struct ThemeSelectionView"))
        #expect(!source.contains("private struct ProTranscriptsSettingsView"))
        #expect(!source.contains("private struct AppIconSelectionView"))
    }

    /// The per-listen Playback section is owned by the Playback Options sheet
    /// (WS-B) now — SettingsView must not render it.
    @Test func settingsViewDropsPlaybackSection() throws {
        let source = try Self.source(named: "SettingsView.swift")
        #expect(!source.contains("Section(\"Playback\")"))
        #expect(!source.contains("Default Speed"))
        #expect(!source.contains("Seek Backward"))
        #expect(!source.contains("Seek Forward"))
    }

    /// Auto-alignment + bookmarks-inline preferences moved into the Advanced
    /// subscreen, which preserves the configureContinuousAlignment side-effect.
    @Test func advancedSubViewOwnsAutoAlignmentAndBookmarks() throws {
        let source = try Self.source(named: "SettingsAdvancedView.swift")
        #expect(source.contains("struct SettingsAdvancedView"))
        #expect(source.contains("configureContinuousAlignment()"))
        #expect(source.contains("playBookmarksInline"))
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    return content
                }
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
