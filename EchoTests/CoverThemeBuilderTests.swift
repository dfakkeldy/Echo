import SwiftUI
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation; nonisolated so the
// init overrides match XCTestCase's nonisolated inits (pure synchronous value tests).
nonisolated final class CoverThemeBuilderTests: XCTestCase {

    /// Fixed stand-in so tests don't depend on the asset-catalog brand color.
    private let brand = ColorMetrics.RGB(r: 1.0, g: 0.36, b: 0.0)

    private func signature(
        hue: Double, chroma: Double = 0.12, lightness: Double = 0.55
    ) -> CoverSignature {
        CoverSignature(
            candidates: [.init(hue: hue, chroma: chroma, weight: 100, lightness: lightness)],
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

    // MARK: - Cover-anchored wash

    func testLightWashAnchorsToPaleCoverTone() {
        // The "Traction" effect: a pale sky-blue cover (observed L 0.85, C 0.06)
        // gets a wash at essentially its own tone, not the fixed L 0.91 — the
        // cover flows into the background.
        let r = CoverThemeBuilder.resolve(
            signature(hue: 250, chroma: 0.06, lightness: 0.85), scheme: .light, brand: brand)
        let top = OKLCH.fromSRGB(r.backgroundTop)
        XCTAssertEqual(top.L, 0.85, accuracy: 0.02)
        XCTAssertEqual(top.C, 0.06, accuracy: 0.015)
    }

    func testLightWashDeepensAndSaturatesForVividMidCover() {
        // A saturated orange cover (L 0.68, C 0.17): the wash lands at the band
        // floor with near-cap chroma — rich apricot, not pale shell.
        let r = CoverThemeBuilder.resolve(
            signature(hue: 55, chroma: 0.17, lightness: 0.68), scheme: .light, brand: brand)
        let top = OKLCH.fromSRGB(r.backgroundTop)
        XCTAssertEqual(top.L, 0.80, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(top.C, 0.10)
    }

    func testDarkWashDeepensForDarkCoverButNeverLightens() {
        let deep = CoverThemeBuilder.resolve(
            signature(hue: 302, chroma: 0.12, lightness: 0.24), scheme: .dark, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(deep.backgroundTop).L, 0.24, accuracy: 0.02)
        // A pale cover must NOT lighten the dark room past the accent-safe
        // ceiling (≈ the old fixed L 0.33): a mid-lightness room can give
        // neither light nor dark accents 3:1, and dark mode stays dark.
        let pale = CoverThemeBuilder.resolve(
            signature(hue: 250, chroma: 0.06, lightness: 0.87), scheme: .dark, brand: brand)
        XCTAssertLessThanOrEqual(OKLCH.fromSRGB(pale.backgroundTop).L, 0.35)
    }

    func testEdgeFieldContinuesExactlyInLightAndFallsBackInDark() {
        var sig = signature(hue: 250, chroma: 0.07, lightness: 0.80)
        sig.edgeField = .init(lightness: 0.86, chroma: 0.055, hue: 250)
        let light = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        let top = OKLCH.fromSRGB(light.backgroundTop)
        XCTAssertEqual(top.L, 0.86, accuracy: 0.01, "in-band edge tone continues exactly")
        XCTAssertEqual(top.C, 0.055, accuracy: 0.01)
        // In dark the pale edge is out of reach; the anchored ramp takes over.
        let dark = CoverThemeBuilder.resolve(sig, scheme: .dark, brand: brand)
        XCTAssertLessThanOrEqual(OKLCH.fromSRGB(dark.backgroundTop).L, 0.35)
    }

    func testNearNeutralEdgeIsNotContinued() {
        // A white border (chroma ≈ 0) has nothing to continue — the tinted
        // anchored ramp keeps the cover-derived identity instead. This guards
        // the 2026-07 lesson: a near-white wash reads as "no theme".
        var sig = signature(hue: 55, chroma: 0.12, lightness: 0.55)
        sig.edgeField = .init(lightness: 0.97, chroma: 0.005, hue: 55)
        let r = CoverThemeBuilder.resolve(sig, scheme: .light, brand: brand)
        let top = OKLCH.fromSRGB(r.backgroundTop)
        XCTAssertEqual(top.L, 0.80, accuracy: 0.02, "wash follows the candidate anchor")
        XCTAssertGreaterThanOrEqual(top.C, 0.04, "and stays visibly tinted")
    }

    func testEdgeContinuationSkipsAmberRotation() {
        // An olive-gold border reproduced exactly must NOT be rotated toward
        // amber — rotation exists for constructed rooms, not colours the cover
        // actually has.
        var sig = signature(hue: 100, chroma: 0.08, lightness: 0.30)
        sig.edgeField = .init(lightness: 0.30, chroma: 0.06, hue: 100)
        let r = CoverThemeBuilder.resolve(sig, scheme: .dark, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(r.backgroundTop).H, 100, accuracy: 3)
    }

    func testBWDominantCoverKeepsDesignedWashAndDeepensUnderBlack() {
        // White-dominant (a red mark on white): the accent bucket's mid tone
        // must not drag the wash — light sits at the pale pole, dark keeps the
        // designed deep room.
        let white = boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.13, nearWhite: 0.53)
        let light = CoverThemeBuilder.resolve(white, scheme: .light, brand: brand)
        XCTAssertGreaterThanOrEqual(OKLCH.fromSRGB(light.backgroundTop).L, 0.90)
        let dark = CoverThemeBuilder.resolve(white, scheme: .dark, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(dark.backgroundTop).L, 0.33, accuracy: 0.02)
        // Black-dominant: the dark room deepens to the band floor — an
        // OLED-true continuation of the black field.
        let black = boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.60, nearWhite: 0.06)
        let deep = CoverThemeBuilder.resolve(black, scheme: .dark, brand: brand)
        XCTAssertEqual(OKLCH.fromSRGB(deep.backgroundTop).L, 0.20, accuracy: 0.02)
    }

    func testEveryHueClearsContrastFloorsAcrossCoverTones() {
        // The anchored wash moves with the cover's own tone, so the floors must
        // hold across the whole (hue × tone) plane in both schemes — edge
        // continuation included.
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for hue in stride(from: 0.0, to: 360.0, by: 5.0) {
                for lightness in [0.15, 0.35, 0.55, 0.75, 0.92] {
                    for chroma in [0.06, 0.17] {
                        var sig = signature(hue: hue, chroma: chroma, lightness: lightness)
                        if Int(hue) % 10 == 0 {
                            // Edge at the cover's own tone for half the grid.
                            sig.edgeField = .init(
                                lightness: lightness, chroma: chroma, hue: hue)
                        }
                        let r = CoverThemeBuilder.resolve(sig, scheme: scheme, brand: brand)
                        assertContrastFloors(
                            r, "hue \(hue) L \(lightness) C \(chroma) \(scheme)")
                    }
                }
            }
        }
    }

    private func assertContrastFloors(_ r: CoverThemeBuilder.Resolved, _ label: String) {
        for bg in [r.backgroundTop, r.backgroundBottom] {
            XCTAssertGreaterThanOrEqual(
                ColorMetrics.contrastRatio(r.accent, bg), CoverThemeBuilder.accentFloor,
                "accent vs bg — \(label)")
            XCTAssertGreaterThanOrEqual(
                ColorMetrics.contrastRatio(r.secondaryAccent, bg), CoverThemeBuilder.accentFloor,
                "secondary vs bg — \(label)")
        }
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.accent, r.chip), CoverThemeBuilder.chipFloor,
            "accent vs chip — \(label)")
        XCTAssertGreaterThanOrEqual(
            ColorMetrics.contrastRatio(r.onAccent, r.accent), CoverThemeBuilder.onAccentFloor,
            "onAccent — \(label)")
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

    // MARK: - Cover appearance mode

    func testPreferredSchemeFollowsAnchorTone() {
        // Pale and vivid-light covers ask for the light room; deep covers for
        // the dark one. The pick must agree with where washPlan would anchor.
        XCTAssertEqual(
            CoverThemeBuilder.preferredScheme(for: signature(hue: 250, lightness: 0.86)), .light)
        XCTAssertEqual(
            CoverThemeBuilder.preferredScheme(for: signature(hue: 43, lightness: 0.71)), .light)
        XCTAssertEqual(
            CoverThemeBuilder.preferredScheme(for: signature(hue: 250, lightness: 0.24)), .dark)
    }

    func testPreferredSchemeMidToneHasNoPreference() {
        // L 0.57 is equidistant from the light (0.80...) and dark (...0.34)
        // bands — forcing either scheme would look arbitrary.
        XCTAssertNil(CoverThemeBuilder.preferredScheme(for: signature(hue: 100, lightness: 0.57)))
    }

    func testPreferredSchemeEdgeFieldOutranksPrimary() {
        // A deep border around a pale centre: the border is the room's seam,
        // so it decides the scheme.
        var deepBorder = signature(hue: 30, lightness: 0.85)
        deepBorder.edgeField = .init(lightness: 0.22, chroma: 0.05, hue: 30)
        XCTAssertEqual(CoverThemeBuilder.preferredScheme(for: deepBorder), .dark)
        // A near-neutral white border is never continued as a colour, but it
        // still says "pale room".
        var whiteBorder = signature(hue: 30, lightness: 0.30)
        whiteBorder.edgeField = .init(lightness: 0.96, chroma: 0.005, hue: 0)
        XCTAssertEqual(CoverThemeBuilder.preferredScheme(for: whiteBorder), .light)
    }

    func testPreferredSchemeBlackWhiteFieldDecides() {
        XCTAssertEqual(
            CoverThemeBuilder.preferredScheme(
                for: boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.13, nearWhite: 0.53)),
            .light)
        XCTAssertEqual(
            CoverThemeBuilder.preferredScheme(
                for: boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.53, nearWhite: 0.13)),
            .dark)
        // A balanced black/white field expresses no preference.
        XCTAssertNil(
            CoverThemeBuilder.preferredScheme(
                for: boldSignature(hue: 22, chroma: 0.162, nearBlack: 0.33, nearWhite: 0.32)))
    }

    func testPreferredSchemeAbsentOrNeutralFollowsSystem() {
        XCTAssertNil(CoverThemeBuilder.preferredScheme(for: nil))
        XCTAssertNil(CoverThemeBuilder.preferredScheme(for: .neutral))
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

    // MARK: - Vivid accent style (core-first promotion)

    /// A teal cover whose red title text antialiases into a pale halo: the red
    /// bucket's MEAN chroma (0.05) sits under the promotion floor, but its
    /// vivid core is unmistakably red. Classic misses it; vivid captures it.
    private let haloDilutedRedTitle = CoverSignature(
        candidates: [
            .init(hue: 190, chroma: 0.11, weight: 100, lightness: 0.73),
            .init(
                hue: 25, chroma: 0.05, weight: 15, lightness: 0.86,
                coreHue: 25, coreChroma: 0.16, coreLightness: 0.62),
        ],
        isNeutral: false
    )

    func testVividAccentPromotesHaloDilutedCore() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let classic = CoverThemeBuilder.resolve(
                haloDilutedRedTitle, scheme: scheme, brand: brand)
            XCTAssertEqual(
                OKLCH.fromSRGB(classic.accent).H, 190, accuracy: 25,
                "classic keeps the primary-hue accent — the diluted mean fails the floor")

            let vivid = CoverThemeBuilder.resolve(
                haloDilutedRedTitle, scheme: scheme, brand: brand, vividAccent: true)
            XCTAssertEqual(
                OKLCH.fromSRGB(vivid.accent).H, 25, accuracy: 25,
                "vivid promotes the red core in \(scheme)")
            XCTAssertEqual(
                OKLCH.fromSRGB(vivid.secondaryAccent).H, 190, accuracy: 25,
                "primary-hue accent moves to the secondary role in \(scheme)")
        }
    }

    func testVividAccentIgnoresMarginalCore() {
        // Core chroma 0.10 clears the mean-calibrated floor (0.09) but not the
        // core floor (0.11): the quartile view inflates chroma by construction,
        // so a bucket marginal even at its most saturated must stay unpromoted.
        let marginal = CoverSignature(
            candidates: [
                .init(hue: 190, chroma: 0.11, weight: 100, lightness: 0.73),
                .init(
                    hue: 25, chroma: 0.05, weight: 15, lightness: 0.86,
                    coreHue: 25, coreChroma: 0.10, coreLightness: 0.62),
            ],
            isNeutral: false
        )
        let vivid = CoverThemeBuilder.resolve(
            marginal, scheme: .light, brand: brand, vividAccent: true)
        XCTAssertEqual(
            OKLCH.fromSRGB(vivid.accent).H, 190, accuracy: 25,
            "marginal core must not promote")
    }

    func testVividAccentFallsBackToMeanSeedWhenCoreDrifts() {
        // The mean view promotes cleanly, but the core sits so light (0.95)
        // that light-scheme enforcement would drift it past the identity gate.
        // Vivid must fall back to the mean seed and match classic exactly —
        // the switch can refine or add a promotion, never lose one.
        let driftingCore = CoverSignature(
            candidates: [
                .init(hue: 190, chroma: 0.11, weight: 100, lightness: 0.73),
                .init(
                    hue: 25, chroma: 0.15, weight: 15, lightness: 0.60,
                    coreHue: 25, coreChroma: 0.30, coreLightness: 0.95),
            ],
            isNeutral: false
        )
        let classic = CoverThemeBuilder.resolve(driftingCore, scheme: .light, brand: brand)
        let vivid = CoverThemeBuilder.resolve(
            driftingCore, scheme: .light, brand: brand, vividAccent: true)
        XCTAssertEqual(
            OKLCH.fromSRGB(classic.accent).H, 25, accuracy: 25,
            "the mean view promotes the red")
        XCTAssertEqual(vivid.accent, classic.accent, "core drift falls back to the mean seed")
        XCTAssertEqual(vivid.secondaryAccent, classic.secondaryAccent)
    }

    func testVividAccentWithoutCoreDataMatchesClassic() {
        // Signatures built without pixel data (stored fixtures, tests) carry
        // no core stats; the vivid style must degrade to classic byte-for-byte.
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let classic = CoverThemeBuilder.resolve(duotoneLeverage, scheme: scheme, brand: brand)
            let vivid = CoverThemeBuilder.resolve(
                duotoneLeverage, scheme: scheme, brand: brand, vividAccent: true)
            XCTAssertEqual(vivid.accent, classic.accent, "\(scheme)")
            XCTAssertEqual(vivid.secondaryAccent, classic.secondaryAccent, "\(scheme)")
            XCTAssertEqual(vivid.backgroundTop, classic.backgroundTop, "\(scheme)")
        }
    }
}
