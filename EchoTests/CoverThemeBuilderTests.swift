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
        // The navy's chroma sits below the promotion floor (0.09) on purpose:
        // this test exercises the secondary-ROLE picker, not accent promotion.
        let sig = CoverSignature(
            candidates: [
                .init(hue: 95, chroma: 0.12, weight: 100),  // gold
                .init(hue: 100, chroma: 0.10, weight: 60),  // near-duplicate — skipped
                .init(hue: 260, chroma: 0.06, weight: 40),  // navy — distinct + heavy enough
            ],
            isNeutral: false
        )
        let r = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 260, accuracy: 20)
        XCTAssertEqual(
            OKLCH.fromSRGB(r.accent).H, 95, accuracy: 20,
            "a dull secondary must not take the accent role")
    }

    func testSecondaryFallsBackToHueSiblingWhenNoDistinctCandidate() {
        let r = CoverThemeBuilder.resolve(signature(hue: 95), scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 125, accuracy: 20)  // 95 + 30
    }

    func testWeakSecondCandidateIsIgnored() {
        // Weight 3 sits under BOTH gates: the secondary role's 15% share and
        // accent promotion's 5% share.
        let sig = CoverSignature(
            candidates: [
                .init(hue: 95, chroma: 0.12, weight: 100),
                .init(hue: 260, chroma: 0.10, weight: 3),
            ],
            isNeutral: false
        )
        let r = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.secondaryAccent).H, 125, accuracy: 20)
        XCTAssertEqual(
            OKLCH.fromSRGB(r.accent).H, 95, accuracy: 20,
            "a stray vivid speck must not take the accent role")
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
            // Ceiling sits well under the standard dark recipe's L 0.78 pale
            // pink, with headroom for `enforcedAccent`'s contrast stepping
            // against the 2026-07 richer (lighter) dark ramp (~L 0.63 at hue 22).
            XCTAssertLessThanOrEqual(
                accent.L, 0.65, "accent should be a bold (low-L) red, not pink, in \(scheme)")
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

    func testBlackWhiteDominantCoverKeepsCoverHuedBackground() {
        // Regression (2026-07): a bold accent on a black/white-dominant cover
        // (e.g. a teal mark on black) must keep a cover-hued room in BOTH
        // schemes. An earlier neutral graphite/paper strip here read as
        // "the theme is just dark" — the background wash is the one place the
        // cover-derived theme is unmistakable, so it never goes neutral while
        // the cover has an identity hue.
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let r = CoverThemeBuilder.resolve(
                boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.13, nearWhite: 0.53),
                scheme: scheme, brand: brand)
            XCTAssertGreaterThan(
                OKLCH.fromSRGB(r.backgroundTop).C, 0.03,
                "background keeps the cover hue in \(scheme)")
            XCTAssertEqual(
                OKLCH.fromSRGB(r.backgroundTop).H, 22, accuracy: 25,
                "background hue family follows the cover in \(scheme)")
        }
    }

    func testRampsAreVisiblyCoverTinted() {
        // The full-screen wash must READ as the cover's colour at a glance
        // (pale tinted paper in light, an immersive coloured room in dark) —
        // not collapse to near-neutral. Floors are generous under the gamut
        // clamp's worst hue, but well above "visually grey" (C ≈ 0.01).
        let light = CoverThemeBuilder.resolve(signature(hue: 55), scheme: .light, brand: brand)
        XCTAssertGreaterThanOrEqual(OKLCH.fromSRGB(light.backgroundTop).C, 0.04)
        XCTAssertGreaterThanOrEqual(OKLCH.fromSRGB(light.backgroundBottom).C, 0.05)
        let dark = CoverThemeBuilder.resolve(signature(hue: 55), scheme: .dark, brand: brand)
        XCTAssertGreaterThanOrEqual(OKLCH.fromSRGB(dark.backgroundTop).C, 0.05)
        XCTAssertGreaterThanOrEqual(OKLCH.fromSRGB(dark.backgroundBottom).C, 0.05)
        // Even at the gamut clamp's tightest hue (blue-violet light / teal dark)
        // the wash stays visibly tinted.
        let blue = CoverThemeBuilder.resolve(signature(hue: 268), scheme: .light, brand: brand)
        XCTAssertGreaterThanOrEqual(OKLCH.fromSRGB(blue.backgroundTop).C, 0.03)
        let teal = CoverThemeBuilder.resolve(signature(hue: 200), scheme: .dark, brand: brand)
        XCTAssertGreaterThanOrEqual(OKLCH.fromSRGB(teal.backgroundTop).C, 0.03)
    }

    func testSolidVividCoverGetsBoldAccentButKeepsTonalBackground() {
        // Bold accent (chroma above the floor) but NOT black/white-dominant: keep a
        // hue-tinted background, only bolden the accent.
        let r = CoverThemeBuilder.resolve(
            boldSignature(hue: 22, chroma: 0.20, nearBlack: 0.0, nearWhite: 0.0),
            scheme: .dark, brand: brand)
        XCTAssertGreaterThan(
            OKLCH.fromSRGB(r.backgroundTop).C, 0.02, "non-B/W cover keeps a tinted background")
        // Same enforcement headroom as testBoldAccentCoverThemesBoldNotPink.
        XCTAssertLessThanOrEqual(OKLCH.fromSRGB(r.accent).L, 0.65, "still a bold accent")
    }

    func testStandardChromaCoverStaysTonal() {
        // Below the bold chroma floor → unchanged standard recipe (light dark-scheme
        // accent), so the 360-hue stand-in (chroma 0.12) keeps testing the original.
        let r = CoverThemeBuilder.resolve(
            signature(hue: 22, chroma: 0.12), scheme: .dark, brand: brand)
        XCTAssertGreaterThan(
            OKLCH.fromSRGB(r.accent).L, 0.65, "standard dark accent stays light/tonal")
    }

    // MARK: - Amber rotation (dark rooms in the yellow band)

    private func roomRoles(_ r: CoverThemeBuilder.Resolved) -> [ColorMetrics.RGB] {
        [r.backgroundTop, r.backgroundBottom, r.chip]
    }

    func testDarkYellowRoomRotatesTowardAmberAndKeepsTheAccentHue() {
        // sRGB has no dark saturated yellow, so the dark recipe at hue 110 lands
        // on #383800 — red and green channels EQUAL, i.e. olive-drab, the
        // "murky brown room". The ramp rotates toward amber until the warm
        // channel leads; what the cover IS (the accent hue) does not move.
        let r = CoverThemeBuilder.resolve(signature(hue: 110), scheme: .dark, brand: brand)
        for surface in roomRoles(r) {
            XCTAssertEqual(
                OKLCH.fromSRGB(surface).H, 96, accuracy: 2,
                "the room rotates ~14° toward amber, not past the band's warm edge")
            XCTAssertGreaterThan(
                surface.r, surface.g,
                "warm channel must lead — equal r/g is exactly the olive-drab bug")
        }
        XCTAssertEqual(
            OKLCH.fromSRGB(r.accent).H, 110, accuracy: 1,
            "the accent keeps the cover's own hue; only the room rotates")
        XCTAssertEqual(
            OKLCH.fromSRGB(r.secondaryAccent).H, 140, accuracy: 1,
            "the secondary keeps its +30° sibling of the COVER hue, not the room hue")
    }

    func testAmberRotationIsDarkSchemeAndBandScoped() {
        // The light recipe's L 0.91 ramp over the same hues is pale cream, which
        // already reads as gold — rotating it would only cost cover fidelity.
        let light = CoverThemeBuilder.resolve(signature(hue: 110), scheme: .light, brand: brand)
        for surface in roomRoles(light) {
            XCTAssertEqual(
                OKLCH.fromSRGB(surface).H, 110, accuracy: 1, "light ramp keeps the cover hue")
        }
        // Just outside either edge of the band, the dark ramp is untouched too:
        // 65° is already amber, and 115° is yellow-GREEN, where rotating down
        // would drop the room INTO the olive pit.
        for hue in [65.0, 115.0] {
            let dark = CoverThemeBuilder.resolve(signature(hue: hue), scheme: .dark, brand: brand)
            for surface in roomRoles(dark) {
                XCTAssertEqual(
                    OKLCH.fromSRGB(surface).H, hue, accuracy: 1,
                    "hue \(hue) sits outside the yellow band and must not rotate")
            }
        }
    }

    func testAmberRotationKeepsBandInteriorCoversDistinct() {
        // The band is compressed toward its warm edge rather than shifted by a
        // fixed amount, so distinct covers keep distinct rooms — a truncating
        // clamp would collapse everything from 70° to 84° onto one hue.
        let rooms = [75.0, 90.0, 105.0].map { hue -> Double in
            let r = CoverThemeBuilder.resolve(signature(hue: hue), scheme: .dark, brand: brand)
            return OKLCH.fromSRGB(r.backgroundTop).H
        }
        XCTAssertLessThan(rooms[0], rooms[1])
        XCTAssertLessThan(rooms[1], rooms[2])
        for (room, cover) in zip(rooms, [75.0, 90.0, 105.0]) {
            XCTAssertLessThan(room, cover, "every band-interior room warms")
            XCTAssertGreaterThanOrEqual(room, 70, "and none overshoots the band's warm edge")
        }
    }

    // MARK: - Accent promotion (duotone covers)

    /// "The Long Leverage" shape: purple-dominant cover with vivid neon-green
    /// bars. The neon is hue-distinct, vivid, and well above the 5% weight
    /// share, so it is promotion-eligible in both schemes; whether it wins
    /// depends on the drift gate per scheme.
    private let duotoneLeverage = CoverSignature(
        candidates: [
            .init(hue: 302, chroma: 0.117, weight: 100, lightness: 0.31),
            .init(hue: 122, chroma: 0.208, weight: 80, lightness: 0.90),
        ],
        isNeutral: false
    )

    func testVividCounterColourIsPromotedToAccent() {
        // Dark scheme: the neon (observed L 0.90) clears every floor against
        // the purple room without moving, so it takes the accent role and the
        // primary-hue accent moves to the secondary role. The room itself
        // always keeps the primary hue.
        let r = CoverThemeBuilder.resolve(duotoneLeverage, scheme: .dark, brand: brand)
        let accent = OKLCH.fromSRGB(r.accent)
        XCTAssertEqual(accent.H, 122, accuracy: 20, "neon counter-colour takes the accent role")
        XCTAssertGreaterThanOrEqual(accent.L, 0.75, "promoted accent keeps the cover's tone")
        XCTAssertEqual(
            OKLCH.fromSRGB(r.secondaryAccent).H, 302, accuracy: 20,
            "primary-hue accent moves to the secondary role")
        for bg in [r.backgroundTop, r.backgroundBottom] {
            XCTAssertEqual(
                OKLCH.fromSRGB(bg).H, 302, accuracy: 25, "room keeps the primary hue")
            XCTAssertGreaterThanOrEqual(
                ColorMetrics.contrastRatio(r.accent, bg), CoverThemeBuilder.accentFloor)
        }
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.accent, r.chip), CoverThemeBuilder.chipFloor)
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.onAccent, r.accent), CoverThemeBuilder.onAccentFloor)
    }

    func testPromotionRejectedWhenEnforcementWouldDriftIdentity() {
        // Light scheme, same cover: clearing 3:1 against the pale wash drags
        // the neon from L 0.90 to ~0.54, where the eye reads olive, not neon.
        // The drift gate rejects it and the accent keeps the primary purple.
        let r = CoverThemeBuilder.resolve(duotoneLeverage, scheme: .light, brand: brand)
        XCTAssertEqual(
            OKLCH.fromSRGB(r.accent).H, 302, accuracy: 20,
            "drifted counter-colour falls back to the primary-hue accent")
    }

    func testGeodeCounterColourRescuesGoldAccent() {
        // Gold geode with purple veins. Gold forced dark enough to clear a
        // cream wash collapses to brown-olive (an sRGB gamut fact — dark vivid
        // yellow does not exist), while the cover's own purple (observed
        // L ≈ 0.50) survives enforcement in both schemes. The veins carry ~7%
        // of the primary's weight — under the secondary role's 15% gate, which
        // is exactly why promotion gates on vividness instead of area.
        let sig = CoverSignature(
            candidates: [
                .init(hue: 82, chroma: 0.12, weight: 100, lightness: 0.74),
                .init(hue: 304, chroma: 0.13, weight: 7, lightness: 0.50),
            ],
            isNeutral: false
        )
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let r = CoverThemeBuilder.resolve(sig, scheme: scheme, brand: brand)
            let accent = OKLCH.fromSRGB(r.accent)
            XCTAssertEqual(
                accent.H, 304, accuracy: 20, "purple veins take the accent in \(scheme)")
            XCTAssertLessThanOrEqual(
                abs(accent.L - 0.50), 0.16, "promoted accent honours the drift gate in \(scheme)")
            XCTAssertEqual(
                OKLCH.fromSRGB(r.backgroundTop).H, 82, accuracy: 25,
                "wash stays gold in \(scheme)")
            for bg in [r.backgroundTop, r.backgroundBottom] {
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.accent, bg), CoverThemeBuilder.accentFloor)
            }
            XCTAssertGreaterThanOrEqual(
                ColorMetrics.contrastRatio(r.onAccent, r.accent), CoverThemeBuilder.onAccentFloor)
        }
    }

    func testPromotedPathClearsContrastFloorsForAllHues() {
        // Whether or not a given (primary, counter) pair promotes, every floor
        // must hold; whenever promotion happens, the enforced accent honours
        // the drift gate relative to the cover's observed lightness.
        func circularDelta(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for hue in 0..<360 {
                let counterHue = Double((hue + 150) % 360)
                let sig = CoverSignature(
                    candidates: [
                        .init(hue: Double(hue), chroma: 0.12, weight: 100, lightness: 0.5),
                        .init(hue: counterHue, chroma: 0.15, weight: 50, lightness: 0.85),
                    ],
                    isNeutral: false
                )
                let r = CoverThemeBuilder.resolve(sig, scheme: scheme, brand: brand)
                for bg in [r.backgroundTop, r.backgroundBottom] {
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.accent, bg), CoverThemeBuilder.accentFloor,
                        "accent vs bg at hue \(hue), \(scheme)")
                    XCTAssertGreaterThanOrEqual(
                        ColorMetrics.contrastRatio(r.secondaryAccent, bg),
                        CoverThemeBuilder.accentFloor,
                        "secondary vs bg at hue \(hue), \(scheme)")
                }
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.accent, r.chip), CoverThemeBuilder.chipFloor,
                    "accent vs chip at hue \(hue), \(scheme)")
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(r.onAccent, r.accent),
                    CoverThemeBuilder.onAccentFloor,
                    "onAccent at hue \(hue), \(scheme)")
                let accent = OKLCH.fromSRGB(r.accent)
                if circularDelta(accent.H, counterHue) < 25 {
                    XCTAssertLessThanOrEqual(
                        abs(accent.L - 0.85), 0.16,
                        "promoted accent at hue \(hue), \(scheme) exceeded the drift gate")
                }
            }
        }
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
