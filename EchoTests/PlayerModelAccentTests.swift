import XCTest
import SwiftUI
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
}
