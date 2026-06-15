import SwiftUI
import XCTest

@testable import Echo

@MainActor
final class PlayerModelAccentTests: XCTestCase {

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
}
