// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Role-based theme derived from one cover's `CoverSignature`.
// `nonisolated`: a pure value theme (SwiftUI `Color`s are Sendable). Under Swift 6
// MainActor default isolation it would be inferred `@MainActor`, blocking the
// nonisolated builder/tests from reading its roles.
nonisolated struct CoverTheme: Equatable {
    let accent: Color  // interactive tint — ≥3:1 vs backgrounds and ≥2.5:1 vs chip
    let onAccent: Color  // glyphs inside accent-filled controls — ≥4.5:1 vs accent
    let secondaryAccent: Color  // gradients, secondary indicators
    let backgroundTop: Color  // AdaptiveBackground ramp
    let backgroundBottom: Color
    let chip: Color  // pills and control circles
    let isNeutralFallback: Bool  // drives artworkAccentColor's nil contract
}

/// Constructs `CoverTheme`s from tone recipes: the hue comes from the cover,
/// lightness and chroma come from per-role constants chosen so the contrast
/// floors hold for every hue. `CoverThemeBuilderTests` sweeps all 360 hues
/// in both schemes to prove it ("correct by construction").
// `nonisolated`: pure theme construction from color math; no main-actor state.
nonisolated enum CoverThemeBuilder {

    /// RGB-typed result used by the property tests; `build` wraps it in Colors.
    struct Resolved: Equatable {
        let accent: ColorMetrics.RGB
        let onAccent: ColorMetrics.RGB
        let secondaryAccent: ColorMetrics.RGB
        let backgroundTop: ColorMetrics.RGB
        let backgroundBottom: ColorMetrics.RGB
        let chip: ColorMetrics.RGB
        let isNeutralFallback: Bool
    }

    private struct Recipe {
        let backgroundTop: (l: Double, c: Double)
        let backgroundBottom: (l: Double, c: Double)
        let chip: (l: Double, c: Double)
        let accent: (l: Double, c: Double)
        let onAccent: (l: Double, c: Double)
    }

    /// Pale tonal ramp (spec §4, light column).
    private static let light = Recipe(
        backgroundTop: (0.96, 0.025),
        backgroundBottom: (0.93, 0.040),
        chip: (0.89, 0.050),
        accent: (0.47, 0.130),
        onAccent: (0.97, 0.020)
    )

    /// Immersive deep tones (spec §4, dark column).
    private static let dark = Recipe(
        backgroundTop: (0.26, 0.045),
        backgroundBottom: (0.21, 0.050),
        chip: (0.32, 0.060),
        accent: (0.78, 0.120),
        onAccent: (0.22, 0.040)
    )

    /// Warm-grey ramp hue for neutral (greyscale / no-artwork) covers.
    private static let neutralHue: Double = 80.0
    private static let neutralRampChroma: Double = 0.010

    /// Bold/vivid accent for high-contrast covers whose primary accent is strongly
    /// saturated (a deep accent on black/white — e.g. the red on "Everything But
    /// the Code"). The standard recipes lighten accents for tonal harmony (the dark
    /// accent at L 0.78 turns a red into a pale pink); these keep the cover's
    /// accent bold. Scheme-specific so it contrasts each scheme's background.
    /// `enforcedAccent` still guarantees the contrast floors on top of these seeds.
    private static let boldAccentDark: (l: Double, c: Double) = (0.57, 0.22)
    private static let boldAccentLight: (l: Double, c: Double) = (0.50, 0.22)

    /// A cover earns the bold accent when its primary candidate's OKLCH chroma is
    /// at least this. Keyed on the accent's own saturation, which is a robust
    /// discriminator: bold covers measure ~0.16+, muted/photographic covers
    /// ~0.03–0.10, with a wide empty gap. Sits above the 360-hue contrast test's
    /// stand-in chroma (0.12) so that sweep keeps exercising the standard recipe.
    private static let boldAccentChromaFloor: Double = 0.14

    /// On top of a bold accent, strip the background to a neutral graphite/paper
    /// ramp (the "black/white + accent" look) only when the cover is itself
    /// black/white-dominant. A solid vivid cover keeps its tonal background.
    private static let neutralRampExtremeShare: Double = 0.45

    /// Contrast floors the construction must clear (spec §7).
    static let accentFloor: Double = 3.0
    static let chipFloor: Double = 2.5
    static let onAccentFloor: Double = 4.5

    // MARK: - Public API

    static func build(from signature: CoverSignature, scheme: ColorScheme) -> CoverTheme {
        let r = resolve(signature, scheme: scheme, brand: ColorMetrics.rgb(Color.accentColor))
        return CoverTheme(
            accent: ColorMetrics.color(r.accent),
            onAccent: ColorMetrics.color(r.onAccent),
            secondaryAccent: ColorMetrics.color(r.secondaryAccent),
            backgroundTop: ColorMetrics.color(r.backgroundTop),
            backgroundBottom: ColorMetrics.color(r.backgroundBottom),
            chip: ColorMetrics.color(r.chip),
            isNeutralFallback: r.isNeutralFallback
        )
    }

    /// Pure core. `brand` is injected so tests don't depend on the asset catalog.
    static func resolve(
        _ signature: CoverSignature,
        scheme: ColorScheme,
        brand: ColorMetrics.RGB
    ) -> Resolved {
        let recipe = scheme == .dark ? dark : light

        guard !signature.isNeutral, let primary = signature.candidates.first else {
            return neutralResolved(recipe: recipe, brand: brand)
        }

        let primaryHue = primary.hue

        // A strongly-saturated primary (a bold cover) keeps a bold accent instead
        // of the tonal-lightened one; if the cover is also black/white-dominant the
        // background ramp goes neutral, giving the "black/white + accent" look.
        let isBoldAccent = primary.chroma >= boldAccentChromaFloor
        let useNeutralRamp =
            isBoldAccent
            && (signature.nearBlackShare + signature.nearWhiteShare) >= neutralRampExtremeShare

        // Background + chip roles: neutral graphite/paper for black/white-dominant
        // covers, else the tonal hue ramp at the cover's primary hue.
        let rampHue = useNeutralRamp ? neutralHue : primaryHue
        func ramp(_ role: (l: Double, c: Double)) -> ColorMetrics.RGB {
            roleColor((role.l, useNeutralRamp ? neutralRampChroma : role.c), hue: rampHue)
        }
        let backgroundTop = ramp(recipe.backgroundTop)
        let backgroundBottom = ramp(recipe.backgroundBottom)
        let chip = ramp(recipe.chip)

        let accentRole =
            isBoldAccent ? (scheme == .dark ? boldAccentDark : boldAccentLight) : recipe.accent
        let accent = enforcedAccent(
            roleColor(accentRole, hue: primaryHue), hue: primaryHue,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip
        )
        let onAccent = legibleOnAccent(for: accent)

        let secondHue = secondaryHue(for: signature, primary: primary)
        let secondary = enforcedAccent(
            roleColor(accentRole, hue: secondHue), hue: secondHue,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip
        )

        return Resolved(
            accent: accent,
            onAccent: onAccent,
            secondaryAccent: secondary,
            backgroundTop: backgroundTop,
            backgroundBottom: backgroundBottom,
            chip: chip,
            isNeutralFallback: false
        )
    }

    /// Glyph colour (text/icons) drawn ON the accent fill: whichever of pure white
    /// or pure black contrasts the accent more. For ANY in-gamut accent the better
    /// extreme clears ≥ 4.58 — the minimum-of-maxima sits at relative luminance
    /// ≈ 0.179 — so this always satisfies `onAccentFloor` (4.5) with no stepping,
    /// and, unlike a single-seeded monotonic step, it has no mid-lightness "dead
    /// zone" where a bold accent could be left with an illegible glyph.
    private static func legibleOnAccent(for accent: ColorMetrics.RGB) -> ColorMetrics.RGB {
        let white = ColorMetrics.RGB(r: 1, g: 1, b: 1)
        let black = ColorMetrics.RGB(r: 0, g: 0, b: 0)
        return ColorMetrics.contrastRatio(white, accent)
            >= ColorMetrics.contrastRatio(black, accent)
            ? white : black
    }

    // MARK: - Role construction

    private static func roleColor(_ role: (l: Double, c: Double), hue: Double) -> ColorMetrics.RGB {
        let c = OKLCH.clampedChroma(L: role.l, C: role.c, H: hue)
        return OKLCH.toSRGB(OKLCH.LCH(L: role.l, C: c, H: hue))
    }

    /// First candidate ≥60° (circular) from the primary with ≥15% of its
    /// weight; otherwise a +30° sibling of the primary (spec §4).
    private static func secondaryHue(
        for signature: CoverSignature,
        primary: CoverSignature.HueCandidate
    ) -> Double {
        for candidate in signature.candidates.dropFirst() {
            let delta = abs(candidate.hue - primary.hue)
            let circular = min(delta, 360 - delta)
            if circular >= 60, candidate.weight >= primary.weight * 0.15 {
                return candidate.hue
            }
        }
        return (primary.hue + 30).truncatingRemainder(dividingBy: 360)
    }

    private static func neutralResolved(recipe: Recipe, brand: ColorMetrics.RGB) -> Resolved {
        let backgroundTop = roleColor((recipe.backgroundTop.l, neutralRampChroma), hue: neutralHue)
        let backgroundBottom = roleColor(
            (recipe.backgroundBottom.l, neutralRampChroma), hue: neutralHue)
        let chip = roleColor((recipe.chip.l, neutralRampChroma), hue: neutralHue)

        let brandHue = OKLCH.fromSRGB(brand).H
        let accent = enforcedAccent(
            brand, hue: brandHue,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip
        )
        let onAccent = legibleOnAccent(for: accent)

        return Resolved(
            accent: accent,
            onAccent: onAccent,
            secondaryAccent: accent,
            backgroundTop: backgroundTop,
            backgroundBottom: backgroundBottom,
            chip: chip,
            isNeutralFallback: true
        )
    }

    // MARK: - Safety valve (spec §4)

    private static func enforcedAccent(
        _ color: ColorMetrics.RGB,
        hue: Double,
        backgrounds: [ColorMetrics.RGB],
        chip: ColorMetrics.RGB
    ) -> ColorMetrics.RGB {
        var result = enforced(color, hue: hue, floor: accentFloor, against: backgrounds)
        result = enforced(result, hue: hue, floor: chipFloor, against: [chip])
        // The chip pass moves L the same direction, but re-verify the backgrounds.
        return enforced(result, hue: hue, floor: accentFloor, against: backgrounds)
    }

    /// Steps lightness away from `surfaces` in 0.01 increments (re-clamping
    /// chroma each step) until every surface clears `floor`. Bounded by L
    /// reaching 0 or 1 — at the bound it returns the max-contrast candidate.
    private static func enforced(
        _ color: ColorMetrics.RGB,
        hue: Double,
        floor: Double,
        against surfaces: [ColorMetrics.RGB]
    ) -> ColorMetrics.RGB {
        func clears(_ rgb: ColorMetrics.RGB) -> Bool {
            surfaces.allSatisfy { ColorMetrics.contrastRatio(rgb, $0) >= floor }
        }
        if clears(color) { return color }

        let meanSurfaceLuminance =
            surfaces
            .map(ColorMetrics.relativeLuminance)
            .reduce(0, +) / Double(surfaces.count)
        let step: Double = meanSurfaceLuminance > 0.5 ? -0.01 : 0.01

        var lch = OKLCH.fromSRGB(color)
        var candidate = color
        while lch.L > 0 && lch.L < 1 {
            lch.L = min(max(lch.L + step, 0), 1)
            let c = OKLCH.clampedChroma(L: lch.L, C: lch.C, H: hue)
            candidate = OKLCH.toSRGB(OKLCH.LCH(L: lch.L, C: c, H: hue))
            if clears(candidate) { return candidate }
        }
        return candidate
    }
}
