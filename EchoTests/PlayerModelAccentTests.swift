// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import XCTest

@testable import Echo

@MainActor
final class PlayerModelAccentTests: XCTestCase {

    private func settings(themeColor: ThemeColor) throws -> SettingsManager {
        let suiteName = "PlayerModelAccentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults, appGroupDefaults: defaults)
        settings.themeColor = themeColor.rawValue
        return settings
    }

    func testNilAccentWithoutArtwork() {
        let model = PlayerModel()
        XCTAssertNil(model.artworkAccentColor)
        XCTAssertNil(model.artworkAccentColorHex)
    }

    func testUIColorSchemeDefaultsToLightAndIsSettable() {
        let model = PlayerModel()
        XCTAssertEqual(model.uiColorScheme, .light)
        model.uiColorScheme = .dark
        XCTAssertEqual(model.uiColorScheme, .dark)
    }

    func testCoverThemeWithoutArtworkIsNeutralFallback() {
        let model = PlayerModel()
        XCTAssertTrue(model.coverTheme.isNeutralFallback)
        XCTAssertNil(model.artworkAccentColor)
    }

    func testCoverThemeChangesWithScheme() {
        let model = PlayerModel()
        model.uiColorScheme = .light
        let light = model.coverTheme
        model.uiColorScheme = .dark
        let dark = model.coverTheme
        XCTAssertNotEqual(light, dark)
    }

    func testResolvedThemeTintUsesCoverThemeAccentWhenArtworkSelected() throws {
        let model = PlayerModel()
        let settings = try settings(themeColor: .artwork)
        model.setSettingsManager(settings)

        XCTAssertTrue(model.coverTheme.isNeutralFallback)
        let tint = try XCTUnwrap(model.resolvedThemeTint)
        XCTAssertEqual(ColorMetrics.rgb(tint), ColorMetrics.rgb(model.coverTheme.accent))
    }

    func testThemeColorSettingsSummaryKeepsArtworkDistinctFromSystem() {
        XCTAssertEqual(ThemeColor.artwork.settingsSummaryTitle, "Artwork")
        XCTAssertEqual(ThemeColor.system.settingsSummaryTitle, "System")
    }
}
