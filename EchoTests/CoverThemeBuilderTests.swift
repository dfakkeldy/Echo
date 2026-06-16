// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import SwiftUI
@testable import Echo

final class CoverThemeBuilderTests: XCTestCase {

    /// Fixed stand-in so tests don't depend on the asset-catalog brand color.
    private let brand = ColorMetrics.RGB(r: 1.0, g: 0.36, b: 0.0)

    private func signature(hue: Double, chroma: Double = 0.12) -> CoverSignature {
        CoverSignature(
            candidates: [.init(hue: hue, chroma: chroma, weight: 100)],
            isNeutral: false
        )
    }

    func testEveryHueClearsContrastFloorsInBothSchemes() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for hue in 0..<360 {
                let r = CoverThemeBuilder.resolve(
                    signature(hue: Double(hue)), scheme: scheme, brand: brand
                )
                for bg in [r.backgroundTop, r.backgroundBottom] {
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.accent, bg),
                        CoverThemeBuilder.accentFloor,
                        "accent vs background at hue \(hue), \(scheme)"
                    )
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.secondaryAccent, bg),
                        CoverThemeBuilder.accentFloor,
                        "secondary vs background at hue \(hue), \(scheme)"
                    )
                }
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.accent, r.chip),
                    CoverThemeBuilder.chipFloor,
                    "accent vs chip at hue \(hue), \(scheme)"
                )
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.onAccent, r.accent),
                    CoverThemeBuilder.onAccentFloor,
                    "onAccent vs accent at hue \(hue), \(scheme)"
                )
            }
        }
    }

    func testCompanyOfOneYellowYieldsLegibleWarmTheme() {
        // The original bug case: extractor golds sit near OKLCH hue ~97.
        let r = CoverThemeBuilder.resolve(signature(hue: 97), scheme: .light, brand: brand)
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.accent, r.backgroundTop), 3.0
        )
        // The hue family is kept (bronze), not swapped for the brand color.
        XCTAssertEqual(OKLCH.fromSRGB(r.accent).H, 97, accuracy: 20)
        XCTAssertFalse(r.isNeutralFallback)
    }

    func testSecondaryHuePicksDistinctCandidate() {
        let sig = CoverSignature(
            candidates: [
                .init(hue: 95, chroma: 0.12, weight: 100),  // gold
                .init(hue: 100, chroma: 0.10, weight: 60),  // near-duplicate — skipped
                .init(hue: 260, chroma: 0.10, weight: 40),  // navy — distinct + heavy enough
            ],
            isNeutral: false
        )
        let r = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 260, accuracy: 20)
    }

    func testSecondaryFallsBackToHueSiblingWhenNoDistinctCandidate() {
        let r = CoverThemeBuilder.resolve(signature(hue: 95), scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 125, accuracy: 20)  // 95 + 30
    }

    func testWeakSecondCandidateIsIgnored() {
        let sig = CoverSignature(
            candidates: [
                .init(hue: 95, chroma: 0.12, weight: 100),
                .init(hue: 260, chroma: 0.10, weight: 5),   // distinct but < 15% of primary
            ],
            isNeutral: false
        )
        let r = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 125, accuracy: 20)
    }

    func testNeutralSignatureProducesNeutralFallback() {
        let r = CoverThemeBuilder.resolve(.neutral, scheme: .light, brand: brand)
        XCTAssertTrue(r.isNeutralFallback)
        XCTAssertLessThanOrEqual(OKLCH.fromSRGB(r.backgroundTop).C, 0.02)  // near-grey ramp
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.accent, r.backgroundTop), 3.0     // brand still legible
        )
    }

    func testDarkSchemeProducesDeepBackgrounds() {
        let r = CoverThemeBuilder.resolve(signature(hue: 40), scheme: .dark, brand: brand)
        XCTAssertLessThan(OKLCH.fromSRGB(r.backgroundTop).L, 0.35)
        XCTAssertLessThan(OKLCH.fromSRGB(r.backgroundBottom).L, 0.30)
    }
}
