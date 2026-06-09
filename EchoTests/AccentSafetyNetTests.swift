import XCTest
import SwiftUI
@testable import Echo

final class AccentSafetyNetTests: XCTestCase {

    private func rgb(_ hex: UInt32) -> ColorMetrics.RGB {
        ColorMetrics.RGB(
            r: Double((hex >> 16) & 0xFF) / 255.0,
            g: Double((hex >> 8) & 0xFF) / 255.0,
            b: Double(hex & 0xFF) / 255.0
        )
    }

    // MARK: - Original pass-through

    func testLegibleAccentPassesThroughUntouched() {
        // Emotional Design orange on peach — saved by the chroma gate.
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xE5821C),
                                        candidates: [],
                                        surface: rgb(0xF1CCB5),
                                        brand: rgb(0xF0982C))
        XCTAssertEqual(r.tier, .original)
        XCTAssertEqual(r.color, rgb(0xE5821C))
    }

    // MARK: - Tier A: Nudge

    func testMuddyGoldIsNudgedInPlace() {
        let surface = rgb(0xE9DCC8)
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xC9A23C),
                                        candidates: [rgb(0xC9A23C)],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        XCTAssertEqual(r.tier, .nudged)
        XCTAssertGreaterThanOrEqual(ColorMetrics.contrastRatio(r.color, surface), ColorMetrics.contrastFloor)
    }

    // MARK: - Tier B: Re-pick

    func testUnnudgeableWinnerEscalatesToRepick() {
        let surface = rgb(0xE9DCC8)
        // Near-white winner needs a huge shift (> budget); navy candidate is already safe.
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xF0EAD8),
                                        candidates: [rgb(0xF0EAD8), rgb(0x34459B)],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        XCTAssertEqual(r.tier, .repicked)
        XCTAssertEqual(r.color, rgb(0x34459B))
    }

    // MARK: - Tier C: Brand fallback

    func testNoUsableCoverHueFallsBackToBrand() {
        let surface = rgb(0xE9DCC8)
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xF0EAD8),
                                        candidates: [],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        XCTAssertEqual(r.tier, .brand)
        XCTAssertGreaterThanOrEqual(ColorMetrics.contrastRatio(r.color, surface), ColorMetrics.contrastFloor)
    }

    // MARK: - Dark scheme

    func testDarkSchemeLeavesLightAccentAlone() {
        let surface = AccentSafetyNet.representativeSurface(background: [rgb(0xC9A23C)], scheme: .dark)
        let r = AccentSafetyNet.resolve(rawAccent: rgb(0xC9A23C),
                                        candidates: [],
                                        surface: surface,
                                        brand: rgb(0xF0982C))
        XCTAssertEqual(r.tier, .original)
    }

    // MARK: - Surface estimation

    func testLightSchemeSurfaceEstimateIsLight() {
        let surface = AccentSafetyNet.representativeSurface(background: [rgb(0xC9A23C)], scheme: .light)
        XCTAssertGreaterThan(ColorMetrics.relativeLuminance(surface), 0.5)
    }
}
