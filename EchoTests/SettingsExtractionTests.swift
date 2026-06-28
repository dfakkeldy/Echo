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

    @Test func readerDefaultsSubViewIsExtracted() throws {
        let source = try Self.source(named: "ReaderDefaultsSettingsView.swift")
        #expect(source.contains("struct ReaderDefaultsSettingsView"))
        #expect(source.contains("readerFontSize"))
        #expect(source.contains("readerLineSpacing"))
        #expect(source.contains("readerCardTint"))
        #expect(source.contains(".accessibilityLabel(\"Line Spacing\")"))
        #expect(source.contains(".accessibilityValue(lineSpacingMultiplierText)"))
    }

    @Test func proTranscriptsSubViewIsExtracted() throws {
        let source = try Self.source(named: "ProTranscriptsSettingsView.swift")
        #expect(source.contains("struct ProTranscriptsSettingsView"))
    }

    @Test func nowPlayingSubViewIsExtracted() throws {
        let source = try Self.source(named: "SettingsNowPlayingView.swift")
        #expect(source.contains("struct SettingsNowPlayingView"))
        #expect(source.contains("Default Speed"))
        #expect(source.contains("PlaybackOptionsSheet.seekDurationOptions"))
        #expect(source.contains("SmartRewindSettingsView()"))
        #expect(source.contains("playBookmarksInline"))
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
        #expect(!source.contains("private struct ReaderDefaultsSettingsView"))
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
        #expect(source.contains("debugLoggingEnabled"))
        #expect(source.contains("Verbose Diagnostic Logging"))
    }

    @Test func advancedSubViewOwnsContextMemoryPrivacyControls() throws {
        let source = try Self.source(named: "SettingsAdvancedView.swift")
        #expect(source.contains("locationCaptureEnabled"))
        #expect(source.contains("ContextMemoryDAO"))
        #expect(source.contains("Delete Context Memory"))
    }

    @Test func settingsShellUsesApprovedInformationArchitecture() throws {
        let source = try Self.source(named: "SettingsView.swift")

        #expect(source.contains("Section(\"Now Playing\")"))
        #expect(source.contains("SettingsNowPlayingView()"))
        #expect(source.contains("Section(\"Appearance\")"))
        #expect(source.contains("SettingsAppearanceView()"))
        #expect(source.contains("Section(\"Controls\")"))
        #expect(source.contains("PhonePlayerSettingsView()"))
        #expect(source.contains("WatchAppSettingsView()"))
        #expect(source.contains("Section(\"Library & Accounts\")"))
        #expect(source.contains("ABSConnectionsSettingsView()"))
        #expect(source.contains("ProTranscriptsSettingsView()"))
        #expect(source.contains("Section(\"Study & Notes\")"))
        #expect(source.contains("SettingsStudyRows()"))
        #expect(source.contains("AllStudyNotesExportView"))
        #expect(source.contains("Section(\"Advanced & Privacy\")"))
        #expect(source.contains("PronunciationDictionaryView(store: .shared)"))
        #expect(source.contains("SettingsAdvancedView()"))
        #expect(source.contains("SettingsSupportAboutSection("))

        #expect(!source.contains("Section(\"Display\")"))
        #expect(!source.contains("Section(\"Store\")"))
        #expect(!source.contains("Section(\"Library Sources\")"))
        #expect(!source.contains("Section(\"Customization\")"))
        #expect(!source.contains("Section(\"Flashcards\")"))
        #expect(!source.contains("Section(\"Data\")"))
        #expect(!source.contains("Section(\"Support\")"))
        #expect(!source.contains("Toggle(\"Volume Boost\""))
    }

    @Test func settingsShellExposesStudyGlobalChapterCap() throws {
        let source = try Self.source(named: "SettingsView.swift")
        #expect(source.contains("SettingsStudyRows()"))
        #expect(source.contains("$settings.studyGlobalNewChapterLimit"))
        #expect(source.contains("Global New Chapters"))
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
