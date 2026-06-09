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

    // MARK: - CIELAB + ΔE76

    func testDeltaE76IsZeroForIdenticalColors() {
        let d = ColorMetrics.deltaE76(rgb(0x808080), rgb(0x808080))
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }

    func testTwoGateSavesVividOrange() {
        // Emotional Design: WCAG ~1.86 (fails) but ΔE ~57 (passes) → legible
        XCTAssertTrue(ColorMetrics.isLegible(rgb(0xE5821C), on: rgb(0xF1CCB5)))
    }

    func testTwoGateFlagsMuddyGold() {
        // Programmer's Brain: WCAG ~1.78 and ΔE ~49 → not legible
        XCTAssertFalse(ColorMetrics.isLegible(rgb(0xC9A23C), on: rgb(0xE9DCC8)))
    }

    // MARK: - Lightness nudge

    func testNudgeDarkensOnLightSurface() {
        let surface = rgb(0xE9DCC8)
        let original = rgb(0xC9A23C)
        let out = ColorMetrics.nudged(original, toClear: ColorMetrics.contrastFloor, against: surface)
        XCTAssertGreaterThanOrEqual(ColorMetrics.contrastRatio(out.color, surface), ColorMetrics.contrastFloor)
        XCTAssertLessThan(out.color.r, original.r) // moved darker
        XCTAssertGreaterThan(out.lightnessShift, 0)
    }

    func testNudgeLightensOnDarkSurface() {
        let surface = rgb(0x1C1A16)
        let original = rgb(0x232018)
        let out = ColorMetrics.nudged(original, toClear: ColorMetrics.contrastFloor, against: surface)
        XCTAssertGreaterThanOrEqual(ColorMetrics.contrastRatio(out.color, surface), ColorMetrics.contrastFloor)
        XCTAssertGreaterThan(out.color.r, original.r) // moved lighter
    }

    func testNudgeNoopWhenAlreadyLegible() {
        let surface = rgb(0xE9DCC8)
        let original = rgb(0x34459B)
        let out = ColorMetrics.nudged(original, toClear: ColorMetrics.contrastFloor, against: surface)
        XCTAssertEqual(out.lightnessShift, 0)
        XCTAssertEqual(out.color, original)
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
