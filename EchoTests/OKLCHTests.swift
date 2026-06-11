import XCTest
@testable import Echo

final class OKLCHTests: XCTestCase {

    func testWhiteHasFullLightnessAndZeroChroma() {
        let lch = OKLCH.fromSRGB(ColorMetrics.RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(lch.L, 1.0, accuracy: 0.001)
        XCTAssertEqual(lch.C, 0.0, accuracy: 0.001)
    }

    func testBlackHasZeroLightnessAndZeroChroma() {
        let lch = OKLCH.fromSRGB(ColorMetrics.RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(lch.L, 0.0, accuracy: 0.001)
        XCTAssertEqual(lch.C, 0.0, accuracy: 0.001)
    }

    func testPureRedMatchesCSSColor4Reference() {
        // CSS Color 4 reference: color(srgb 1 0 0) == oklch(0.627955 0.257683 29.2339)
        let lch = OKLCH.fromSRGB(ColorMetrics.RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(lch.L, 0.627955, accuracy: 0.001)
        XCTAssertEqual(lch.C, 0.257683, accuracy: 0.001)
        XCTAssertEqual(lch.H, 29.2339, accuracy: 0.1)
    }

    func testRoundTripPreservesInGamutColor() {
        let original = ColorMetrics.RGB(r: 0.91, g: 0.76, b: 0.17)
        let back = OKLCH.toSRGB(OKLCH.fromSRGB(original))
        XCTAssertEqual(back.r, original.r, accuracy: 0.001)
        XCTAssertEqual(back.g, original.g, accuracy: 0.001)
        XCTAssertEqual(back.b, original.b, accuracy: 0.001)
    }

    func testClampedChromaReturnsInputWhenAlreadyInGamut() {
        XCTAssertEqual(OKLCH.clampedChroma(L: 0.5, C: 0.05, H: 200), 0.05, accuracy: 1e-9)
    }

    func testClampedChromaReducesOutOfGamutChromaAndPreservesLightness() {
        // Near-white yellow at C 0.30 is far outside sRGB.
        let clamped = OKLCH.clampedChroma(L: 0.97, C: 0.30, H: 95)
        XCTAssertLessThan(clamped, 0.30)
        let rgb = OKLCH.toSRGB(OKLCH.LCH(L: 0.97, C: clamped, H: 95))
        XCTAssertEqual(OKLCH.fromSRGB(rgb).L, 0.97, accuracy: 0.01)
    }

    func testHueSweepStaysInGamutAfterClamp() {
        for hue in stride(from: 0.0, to: 360.0, by: 7.0) {
            let c = OKLCH.clampedChroma(L: 0.47, C: 0.13, H: hue)
            let rgb = OKLCH.toSRGB(OKLCH.LCH(L: 0.47, C: c, H: hue))
            for v in [rgb.r, rgb.g, rgb.b] {
                XCTAssertGreaterThanOrEqual(v, 0, "hue \(hue) below gamut")
                XCTAssertLessThanOrEqual(v, 1, "hue \(hue) above gamut")
            }
        }
    }
}
