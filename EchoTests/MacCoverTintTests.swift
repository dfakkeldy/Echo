// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import XCTest

@testable import Echo

/// `MacCoverTint` is the macOS window tint, but it is exercised here: the
/// `Echo macOS` target has no unit-test bundle, so the only way a Mac decision
/// gets automated coverage is by living in `EchoCore` as a pure function. Same
/// arrangement as `MacChapterLoopDecision`.
// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation; nonisolated so the
// init overrides match XCTestCase's nonisolated inits (pure synchronous value tests).
nonisolated final class MacCoverTintTests: XCTestCase {

    // MARK: - Fixtures

    /// A plain single-hue cover.
    private func signature(hue: Double, chroma: Double = 0.15) -> CoverSignature {
        CoverSignature(
            candidates: [.init(hue: hue, chroma: chroma, weight: 100, lightness: 0.5)],
            isNeutral: false
        )
    }

    /// A duotone cover whose counter-colour is thin saturated typography: its
    /// bucket MEAN chroma is diluted below the classic promotion floor (0.09)
    /// by antialiasing halo, while its vivid CORE clears the core floor (0.11).
    /// This is precisely the case the Vivid Cover Accent setting exists for, so
    /// it is the fixture that can tell the two styles apart.
    private var thinTypographyCover: CoverSignature {
        CoverSignature(
            candidates: [
                .init(hue: 200, chroma: 0.15, weight: 100, lightness: 0.5),
                .init(
                    hue: 20, chroma: 0.06, weight: 20, lightness: 0.55,
                    coreHue: 20, coreChroma: 0.16, coreLightness: 0.55),
            ],
            isNeutral: false
        )
    }

    private func rgb(_ color: Color?) -> ColorMetrics.RGB? {
        color.map(ColorMetrics.rgb)
    }

    private func assertSameColor(
        _ lhs: Color?, _ rhs: Color?, accuracy: Double = 0.001,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let l = rgb(lhs), let r = rgb(rhs) else {
            XCTFail(
                "expected two colors, got \(String(describing: lhs)) / \(String(describing: rhs)) \(message)",
                file: file, line: line)
            return
        }
        XCTAssertEqual(l.r, r.r, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(l.g, r.g, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(l.b, r.b, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Static preferences pass through

    func testStaticThemeColorPassesThroughUnchanged() {
        let tint = MacCoverTint.tint(
            themeColor: "Blue", signature: signature(hue: 30), vividAccent: false, scheme: .light)
        assertSameColor(tint, Color.blue, "a static pick must ignore the cover entirely")
    }

    func testSystemReturnsNilSoTheOSTintStands() {
        XCTAssertNil(
            MacCoverTint.tint(
                themeColor: "System", signature: signature(hue: 30), vividAccent: false,
                scheme: .light))
    }

    func testUnrecognizedPreferenceFallsBackToArtwork() {
        let unknown = MacCoverTint.tint(
            themeColor: "Chartreuse", signature: signature(hue: 30), vividAccent: false,
            scheme: .light)
        let artwork = MacCoverTint.tint(
            themeColor: "Artwork", signature: signature(hue: 30), vividAccent: false,
            scheme: .light)
        assertSameColor(
            unknown, artwork, "an unknown stored value must behave as Artwork, as on iOS")
    }

    // MARK: - Artwork mirrors the shared builder

    /// The parity property: macOS must not re-derive the accent, it must ask the
    /// same builder iOS does. If this drifts, the same book shows two different
    /// accents on two devices.
    func testArtworkMatchesTheSharedBuilder() {
        for scheme in [ColorScheme.light, .dark] {
            for vivid in [false, true] {
                let cover = thinTypographyCover
                let tint = MacCoverTint.tint(
                    themeColor: "Artwork", signature: cover, vividAccent: vivid, scheme: scheme)
                let expected = CoverThemeBuilder.build(
                    from: cover, scheme: scheme, vividAccent: vivid
                ).accent
                assertSameColor(tint, expected, "scheme \(scheme), vivid \(vivid)")
            }
        }
    }

    func testArtworkClearsTheAccentContrastFloorAgainstItsOwnWash() {
        for scheme in [ColorScheme.light, .dark] {
            let cover = signature(hue: 140)
            guard
                let accent = rgb(
                    MacCoverTint.tint(
                        themeColor: "Artwork", signature: cover, vividAccent: false, scheme: scheme)
                )
            else { return XCTFail("Artwork must always resolve to a colour") }
            let roles = CoverThemeBuilder.resolve(
                cover, scheme: scheme, brand: ColorMetrics.rgb(Color.accentColor))
            for background in [roles.backgroundTop, roles.backgroundBottom] {
                XCTAssertGreaterThanOrEqual(
                    ColorMetrics.contrastRatio(accent, background),
                    CoverThemeBuilder.accentFloor,
                    "accent vs wash in \(scheme)"
                )
            }
        }
    }

    func testLightAndDarkResolveDifferently() {
        let cover = signature(hue: 260)
        let light = rgb(
            MacCoverTint.tint(
                themeColor: "Artwork", signature: cover, vividAccent: false, scheme: .light))
        let dark = rgb(
            MacCoverTint.tint(
                themeColor: "Artwork", signature: cover, vividAccent: false, scheme: .dark))
        XCTAssertNotEqual(light, dark, "the recipes differ per scheme; the tint must too")
    }

    // MARK: - The two-argument overload

    /// The wash and the accent must be two readings of one theme, not two
    /// builds. The overload exists so `MacPlayerModel` can memoize a single
    /// `CoverThemeBuilder` pass and serve both; if it ever disagreed with the
    /// convenience form, the transport controls would be tinted against a wash
    /// they were never contrast-checked on.
    func testPrebuiltThemeOverloadAgreesWithTheConvenienceForm() {
        let cover = thinTypographyCover
        for scheme in [ColorScheme.light, .dark] {
            for vivid in [false, true] {
                let theme = MacCoverTint.theme(
                    signature: cover, vividAccent: vivid, scheme: scheme)
                for preference in ["Artwork", "System", "Blue", "Chartreuse"] {
                    let viaTheme = MacCoverTint.tint(themeColor: preference, coverTheme: theme)
                    let direct = MacCoverTint.tint(
                        themeColor: preference, signature: cover, vividAccent: vivid,
                        scheme: scheme)
                    if direct == nil {
                        XCTAssertNil(viaTheme, "\(preference) in \(scheme), vivid \(vivid)")
                    } else {
                        assertSameColor(
                            viaTheme, direct, "\(preference) in \(scheme), vivid \(vivid)")
                    }
                }
            }
        }
    }

    /// The wash follows the book even when the accent does not — the same
    /// arrangement `PlayerModel.coverTheme` has on iOS. `theme` taking no
    /// `themeColor` is what enforces it, so this pins the behaviour that
    /// structure buys: a static accent pick leaves the wash cover-derived.
    func testThemeIsIndependentOfTheAccentPreference() {
        let cover = signature(hue: 300)
        let theme = MacCoverTint.theme(signature: cover, vividAccent: false, scheme: .dark)
        let staticPick = MacCoverTint.tint(themeColor: "Blue", coverTheme: theme)
        assertSameColor(staticPick, Color.blue, "the accent must obey the preference")
        let artworkAccent = MacCoverTint.tint(themeColor: "Artwork", coverTheme: theme)
        XCTAssertNotEqual(
            rgb(artworkAccent), rgb(staticPick),
            "the cover accent and a static pick must be distinguishable on this fixture")
        for background in [theme.backgroundTop, theme.backgroundBottom] {
            XCTAssertNotEqual(
                rgb(background), rgb(Color.blue),
                "the wash must stay cover-derived regardless of the accent preference")
        }
    }

    // MARK: - The no-nil contract for Artwork

    /// Deliberate, and deliberately different from a `?? .accentColor` fallback:
    /// a greyscale cover resolves through the builder's neutral path, which
    /// seeds from the brand accent and contrast-enforces it. iOS behaves this
    /// way (`PlayerModel.resolvedTint(for:)`), so macOS must too.
    func testArtworkOnANeutralCoverStillResolves() {
        XCTAssertNotNil(
            MacCoverTint.tint(
                themeColor: "Artwork", signature: .neutral, vividAccent: false, scheme: .dark))
    }

    func testArtworkWithNoArtworkLoadedMatchesTheNeutralCover() {
        let none = MacCoverTint.tint(
            themeColor: "Artwork", signature: nil, vividAccent: false, scheme: .dark)
        let neutral = MacCoverTint.tint(
            themeColor: "Artwork", signature: .neutral, vividAccent: false, scheme: .dark)
        assertSameColor(none, neutral, "a missing cover is the neutral cover")
    }

    // MARK: - Vivid Cover Accent actually does something

    /// The toggle shipped on macOS with no consumer at all. This is its first
    /// regression guard: on the thin-typography fixture, vivid promotes the
    /// counter-colour that the bucket means miss.
    func testVividPromotesAThinSaturatedCounterColour() {
        let cover = thinTypographyCover
        guard
            let classic = rgb(
                MacCoverTint.tint(
                    themeColor: "Artwork", signature: cover, vividAccent: false, scheme: .dark)),
            let vivid = rgb(
                MacCoverTint.tint(
                    themeColor: "Artwork", signature: cover, vividAccent: true, scheme: .dark))
        else { return XCTFail("Artwork must always resolve to a colour") }

        // Contrast enforcement walks lightness at a fixed hue, so the hue that
        // comes out is the hue that was seeded — a clean way to name which
        // candidate won the accent role.
        XCTAssertEqual(OKLCH.fromSRGB(classic).H, 200, accuracy: 1.0, "means keep the primary hue")
        XCTAssertEqual(
            OKLCH.fromSRGB(vivid).H, 20, accuracy: 1.0, "the core promotes the counter-colour")
    }

    /// Vivid is a refinement, never a regression: a cover the classic style
    /// already promotes must still promote the same hue with vivid on.
    func testVividNeverLosesAPromotionTheMeansEarn() {
        let cover = CoverSignature(
            candidates: [
                .init(hue: 200, chroma: 0.15, weight: 100, lightness: 0.5),
                .init(hue: 20, chroma: 0.14, weight: 30, lightness: 0.55),
            ],
            isNeutral: false
        )
        for scheme in [ColorScheme.light, .dark] {
            guard
                let classic = rgb(
                    MacCoverTint.tint(
                        themeColor: "Artwork", signature: cover, vividAccent: false, scheme: scheme)
                ),
                let vivid = rgb(
                    MacCoverTint.tint(
                        themeColor: "Artwork", signature: cover, vividAccent: true, scheme: scheme))
            else { return XCTFail("Artwork must always resolve to a colour") }
            XCTAssertEqual(
                OKLCH.fromSRGB(classic).H, OKLCH.fromSRGB(vivid).H, accuracy: 1.0,
                "vivid must not move an accent the means already chose (\(scheme))")
        }
    }
}
