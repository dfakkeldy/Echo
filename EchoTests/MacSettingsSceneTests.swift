// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Source-scanning structural tests for the macOS Settings scene + MacSettingsView.
/// They verify the App declares a `Settings` scene, injects a `SettingsManager`,
/// applies appearance, and that MacSettingsView has the expected panes/bindings —
/// without launching AppKit. Reuses the shared `MacSource` resolver (G2).
struct MacSettingsSceneTests {

    @Test("App declares a Settings scene wired to MacSettingsView")
    func appHasSettingsScene() throws {
        let src = try MacSource.read("Echo_macOSApp.swift")
        #expect(src.contains("Settings {"))
        #expect(src.contains("MacSettingsView()"))
    }

    @Test("App instantiates and injects a SettingsManager")
    func appInjectsSettingsManager() throws {
        let src = try MacSource.read("Echo_macOSApp.swift")
        #expect(src.contains("SettingsManager()"))
        #expect(src.contains(".environment(settings)"))
    }

    @Test("Main window applies appearance from settings")
    func mainWindowAppliesAppearance() throws {
        let src = try MacSource.read("Echo_macOSApp.swift")
        #expect(src.contains("preferredColorScheme"))
    }

    @Test("Main window applies font and tint from settings")
    func mainWindowAppliesFontAndTint() throws {
        let src = try MacSource.read("Echo_macOSApp.swift")
        #expect(src.contains(".tint(Self.tintColor(for: settings.themeColor))"))
        #expect(src.contains(".customFont(.body, appFont: settings.appFont)"))
        #expect(src.contains("ThemeColor(rawValue: themeColor)?.color ?? .accentColor"))
    }

    @Test("MacSettingsView exists with Appearance, Playback, and Support panes")
    func macSettingsViewHasPanes() throws {
        let src = try MacSource.read("Views/MacSettingsView.swift")
        #expect(src.contains("struct MacSettingsView: View"))
        #expect(src.contains("TabView"))
        #expect(src.contains("Appearance"))
        #expect(src.contains("Playback"))
        #expect(src.contains("Support"))
        #expect(src.contains("MacSupportSettingsPane"))
        #expect(src.contains("FeedbackSupport.emailURL"))
        #expect(src.contains("FeedbackSupport.githubIssuesURL"))
    }

    @Test("MacSettingsView binds appearance, font, theme, speed")
    func macSettingsViewBindsSettings() throws {
        let src = try MacSource.read("Views/MacSettingsView.swift")
        #expect(src.contains("appAppearance"))
        #expect(src.contains("appFont"))
        #expect(src.contains("themeColor"))
        #expect(src.contains("defaultPlaybackSpeed"))
    }

    @Test("MacSettingsView volume-boost toggle uses the shared global key")
    func macSettingsViewVolumeBoostKey() throws {
        let src = try MacSource.read("Views/MacSettingsView.swift")
        #expect(src.contains("global_volumeBoostEnabled"))
    }

    @Test("Mac More-menu opens the Settings scene via SettingsLink")
    func moreMenuOpensSettings() throws {
        let src = try MacSource.read("Views/MacPlayerMoreMenu.swift")
        #expect(src.contains("SettingsLink"))
        #expect(src.contains("Settings"))
    }
}
