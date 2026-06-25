// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural test: MacPlayerModel must consume the injected SettingsManager
/// (skip interval + default speed), wired from MacTriPaneView.task — the same
/// pattern used for dbService. Source-scanned via the shared MacSource resolver.
struct MacSettingsConsumptionTests {
    @Test func macPlayerModelHasSettingsSeam() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(src.contains("var settings: SettingsManager?"))
        #expect(src.contains("settings?.seekForwardDuration"))
        #expect(src.contains("settings?.defaultPlaybackSpeed"))
    }

    @Test func triPaneInjectsSettingsIntoModel() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(src.contains("@Environment(SettingsManager.self)"))
        #expect(src.contains("player.settings = settings"))
    }

    @Test func triPaneAppliesConfiguredFontToPlayerChrome() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(src.contains("customFont(.caption, appFont: settings.appFont)"))
        #expect(src.contains("customFont(.caption2, appFont: settings.appFont)"))
    }

    @Test func readerAppliesConfiguredFontToFeedAndCards() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(src.contains("@Environment(SettingsManager.self)"))
        #expect(src.contains("appFont: settings.appFont"))
        #expect(src.contains("customFont(.body, appFont: appFont)"))
        #expect(src.contains("lhs.appFont == rhs.appFont"))
    }
}
