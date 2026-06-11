import XCTest
@testable import Echo

final class ColorMetricsTests: XCTestCase {

    /// Build an `RGB` from a 0xRRGGBB literal for readable fixtures.
    private func rgb(_ hex: UInt32) -> ColorMetrics.RGB {
        ColorMetrics.RGB(
            r: Double((hex >> 16) & 0xFF) / 255.0,
            g: Double((hex >> 8) & 0xFF) / 255.0,
            b: Double(hex & 0xFF) / 255.0
        )
    }

    // MARK: - WCAG contrast

    func testBlackWhiteMaximumContrast() {
        let c = ColorMetrics.contrastRatio(rgb(0x000000), rgb(0xFFFFFF))
        XCTAssertEqual(c, 21.0, accuracy: 0.1)
    }

    func testGoldOnBeigeReproducesDiagnosedContrast() {
        let c = ColorMetrics.contrastRatio(rgb(0xC9A23C), rgb(0xE9DCC8))
        XCTAssertEqual(c, 1.78, accuracy: 0.05)
    }

    func testContrastIsSymmetric() {
        let a = ColorMetrics.contrastRatio(rgb(0xC9A23C), rgb(0xE9DCC8))
        let b = ColorMetrics.contrastRatio(rgb(0xE9DCC8), rgb(0xC9A23C))
        XCTAssertEqual(a, b, accuracy: 0.0001)
    }

    // MARK: - Color bridge

    func testColorBridgeRoundTripsWithinTolerance() {
        let original = rgb(0xC9A23C)
        let back = ColorMetrics.rgb(ColorMetrics.color(original))
        XCTAssertEqual(back.r, original.r, accuracy: 0.02)
        XCTAssertEqual(back.g, original.g, accuracy: 0.02)
        XCTAssertEqual(back.b, original.b, accuracy: 0.02)
    }
}
