import SwiftUI
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation; nonisolated so the
// init overrides match XCTestCase's nonisolated inits (pure synchronous value tests).
nonisolated final class CoverThemeBuilderTests: XCTestCase {

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
                .init(hue: 260, chroma: 0.10, weight: 5),  // distinct but < 15% of primary
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
            ColorMetrics.contrastRatio(r.accent, r.backgroundTop), 3.0  // brand still legible
        )
    }

    func testDarkSchemeProducesDeepBackgrounds() {
        let r = CoverThemeBuilder.resolve(signature(hue: 40), scheme: .dark, brand: brand)
        XCTAssertLessThan(OKLCH.fromSRGB(r.backgroundTop).L, 0.35)
        XCTAssertLessThan(OKLCH.fromSRGB(r.backgroundBottom).L, 0.30)
    }

    // MARK: - Bold accent for high-contrast covers

    private func boldSignature(
        hue: Double, chroma: Double, nearBlack: Double, nearWhite: Double
    ) -> CoverSignature {
        CoverSignature(
            candidates: [.init(hue: hue, chroma: chroma, weight: 100)],
            isNeutral: false,
            nearBlackShare: nearBlack,
            nearWhiteShare: nearWhite
        )
    }

    func testBoldAccentCoverThemesBoldNotPink() {
        // "Everything But the Code": red primary (OKLCH hue ≈ 22°) at bold chroma
        // 0.162, black/white-dominant. The accent must stay a BOLD red (low
        // lightness), not the pale pink the standard dark recipe (L 0.78) yields.
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let r = CoverThemeBuilder.resolve(
                boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.13, nearWhite: 0.53),
                scheme: scheme, brand: brand)
            let accent = OKLCH.fromSRGB(r.accent)
            XCTAssertLessThanOrEqual(
                accent.L, 0.62, "accent should be a bold (low-L) red, not pink, in \(scheme)")
            XCTAssertTrue(
                accent.H < 45 || accent.H > 350,
                "accent stays in the red family in \(scheme), got hue \(accent.H)")
            XCTAssertGreaterThanOrEqual(
                ColorMetrics.contrastRatio(r.onAccent, r.accent), CoverThemeBuilder.onAccentFloor,
                "glyph stays legible on the bold accent in \(scheme)")
            for bg in [r.backgroundTop, r.backgroundBottom] {
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.accent, bg), CoverThemeBuilder.accentFloor)
            }
        }
    }

    func testBlackWhiteDominantCoverGetsNeutralBackgroundRamp() {
        let r = CoverThemeBuilder.resolve(
            boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.13, nearWhite: 0.53),
            scheme: .dark, brand: brand)
        XCTAssertLessThanOrEqual(
            OKLCH.fromSRGB(r.backgroundTop).C, 0.03,
            "background ramp should be near-neutral graphite")
        XCTAssertLessThanOrEqual(OKLCH.fromSRGB(r.backgroundBottom).C, 0.03)
    }

    func testSolidVividCoverGetsBoldAccentButKeepsTonalBackground() {
        // Bold accent (chroma above the floor) but NOT black/white-dominant: keep a
        // hue-tinted background, only bolden the accent.
        let r = CoverThemeBuilder.resolve(
            boldSignature(hue: 22, chroma: 0.20, nearBlack: 0.0, nearWhite: 0.0),
            scheme: .dark, brand: brand)
        XCTAssertGreaterThan(
            OKLCH.fromSRGB(r.backgroundTop).C, 0.02, "non-B/W cover keeps a tinted background")
        XCTAssertLessThanOrEqual(OKLCH.fromSRGB(r.accent).L, 0.62, "still a bold accent")
    }

    func testStandardChromaCoverStaysTonal() {
        // Below the bold chroma floor → unchanged standard recipe (light dark-scheme
        // accent), so the 360-hue stand-in (chroma 0.12) keeps testing the original.
        let r = CoverThemeBuilder.resolve(
            signature(hue: 22, chroma: 0.12), scheme: .dark, brand: brand)
        XCTAssertGreaterThan(
            OKLCH.fromSRGB(r.accent).L, 0.65, "standard dark accent stays light/tonal")
    }

    func testEveryHueClearsContrastFloorsAtBoldChroma() {
        // The bold recipe + legibleOnAccent must clear every floor for ALL hues in
        // both schemes — proving the bold path is hue-universal (no dead zone).
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for hue in 0..<360 {
                let r = CoverThemeBuilder.resolve(
                    signature(hue: Double(hue), chroma: 0.18), scheme: scheme, brand: brand)
                for bg in [r.backgroundTop, r.backgroundBottom] {
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.accent, bg), CoverThemeBuilder.accentFloor,
                        "bold accent vs bg at hue \(hue), \(scheme)")
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.secondaryAccent, bg),
                        CoverThemeBuilder.accentFloor,
                        "bold secondary vs bg at hue \(hue), \(scheme)")
                }
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.accent, r.chip), CoverThemeBuilder.chipFloor,
                    "bold accent vs chip at hue \(hue), \(scheme)")
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.onAccent, r.accent),
                    CoverThemeBuilder.onAccentFloor,
                    "bold onAccent at hue \(hue), \(scheme)")
            }
        }
    }
}
