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

    /// Tinted paper ramp (spec §4, light column; chroma raised 2026-07 so the
    /// wash visibly reads as the cover's colour — the earlier near-white ramp
    /// plus a NavigationStack occlusion left the player looking untinted).
    /// Extreme hues ride the gamut clamp (`clampedChroma`) and soften gracefully.
    private static let light = Recipe(
        backgroundTop: (0.91, 0.070),
        backgroundBottom: (0.86, 0.095),
        chip: (0.82, 0.105),
        accent: (0.47, 0.130),
        onAccent: (0.97, 0.020)
    )

    /// Immersive coloured room (spec §4, dark column; same 2026-07 chroma raise).
    private static let dark = Recipe(
        backgroundTop: (0.33, 0.085),
        backgroundBottom: (0.26, 0.095),
        chip: (0.39, 0.110),
        accent: (0.78, 0.120),
        onAccent: (0.22, 0.040)
    )

    /// Warm-grey ramp hue for neutral (greyscale / no-artwork) covers.
    private static let neutralHue: Double = 80.0
    private static let neutralRampChroma: Double = 0.010

    // MARK: - Amber rotation (dark rooms in the yellow band)

    /// sRGB has no dark saturated yellow, so the dark recipe's L 0.33 room at a
    /// yellow-band hue lands on olive-drab instead of the warm gold the cover
    /// promises: at hue 110 it resolves to #383800 — red and green channels
    /// equal, army-surplus green. Rotating the ROOM toward amber recovers the
    /// warmth (the same recipe gives #403400 at hue 96) without touching what
    /// the cover IS.
    ///
    /// Dark scheme only: the light recipe's L 0.91 ramp over the same hues is
    /// pale cream, which already reads as gold. Background and chip only: the
    /// dark accent sits at L 0.78, high enough to still read as yellow, so it
    /// keeps the cover's true hue and the rotation costs at most
    /// `amberRotation` degrees of accent-vs-room split.
    ///
    /// The band is COMPRESSED toward its warm edge rather than shifted by a
    /// fixed amount. Two consequences, both wanted: covers inside the band stay
    /// distinguishable from one another (a truncating clamp would give a 70°
    /// cover and an 84° cover the identical room), and the warm edge stays
    /// continuous with the oranges just below it. The cool edge is a genuine
    /// cliff, and deliberately so — hues above `upperBound` are yellow-GREEN,
    /// and easing them down would drop them into the very olive pit this
    /// rotation exists to climb out of.
    private static let amberBand: ClosedRange<Double> = 70...110
    private static let amberRotation: Double = 14.0

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
    /// Unlike the accent, the BACKGROUND ramp always keeps the cover hue — a
    /// neutral graphite/paper strip for black/white-dominant covers was tried
    /// (PR #330) and read as "the theme is just dark/white", losing the
    /// cover-derived identity the wash exists to carry.
    private static let boldAccentChromaFloor: Double = 0.14

    /// Contrast floors the construction must clear (spec §7).
    static let accentFloor: Double = 3.0
    static let chipFloor: Double = 2.5
    static let onAccentFloor: Double = 4.5

    // MARK: - Accent promotion (duotone covers)

    /// A vivid secondary hue can take the ACCENT role — the background ramp
    /// always keeps the primary hue (identity), but a cover that carries a
    /// distinct counter-colour (neon green on a purple cover, purple veins in
    /// a gold geode) reads far richer with that counter-colour as the tint.
    /// Eligibility is gated on VIVIDNESS, not area: `weight` is
    /// saturation²×coverage and thus area-dominated, which is right for
    /// choosing the background but wrong for an accent — a bold element at
    /// ~6% weight (the geode's purple) is exactly what promotion exists for.
    /// The old 15%-weight gate remains on the secondary-role picker below.
    private static let promotionHueSeparation: Double = 60.0
    private static let promotionChromaFloor: Double = 0.09
    private static let promotionWeightShare: Double = 0.05

    /// Identity-drift gate: the promoted accent is seeded from the cover's own
    /// observed colour (its bucket L/C), then contrast-enforced. If enforcement
    /// must move lightness further than this, the colour has lost the identity
    /// that justified promoting it (a neon at L 0.90 dragged to L 0.54 against
    /// a pale wash reads olive, not neon) — fall back to the primary-hue
    /// accent, which the recipes already make legible for every hue.
    private static let promotionMaxLightnessDrift: Double = 0.15
    /// The enforced result must also stay saturated enough to read as a
    /// colour, not a grey — the gamut clamp can hollow out chroma while L
    /// stays put.
    private static let promotionMinChroma: Double = 0.10

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
        // of the tonal-lightened one. The background/chip ramp always follows the
        // cover's primary hue — even for black/white-dominant covers.
        let isBoldAccent = primary.chroma >= boldAccentChromaFloor

        let roomHue = amberedRampHue(primaryHue, scheme: scheme)
        let backgroundTop = roleColor(recipe.backgroundTop, hue: roomHue)
        let backgroundBottom = roleColor(recipe.backgroundBottom, hue: roomHue)
        let chip = roleColor(recipe.chip, hue: roomHue)

        let accentRole =
            isBoldAccent ? (scheme == .dark ? boldAccentDark : boldAccentLight) : recipe.accent
        let primaryAccent = enforcedAccent(
            roleColor(accentRole, hue: primaryHue), hue: primaryHue,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip
        )

        // Duotone promotion: a vivid counter-colour takes the accent role and
        // the primary-hue accent moves to the secondary role. Without a
        // promotable candidate, both roles keep their original construction.
        let accent: ColorMetrics.RGB
        let secondary: ColorMetrics.RGB
        if let promoted = promotedAccent(
            for: signature, primary: primary,
            backgrounds: [backgroundTop, backgroundBottom], chip: chip)
        {
            accent = promoted
            secondary = primaryAccent
        } else {
            accent = primaryAccent
            let secondHue = secondaryHue(for: signature, primary: primary)
            secondary = enforcedAccent(
                roleColor(accentRole, hue: secondHue), hue: secondHue,
                backgrounds: [backgroundTop, backgroundBottom], chip: chip
            )
        }
        let onAccent = legibleOnAccent(for: accent)

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

    /// Hue for the dark scheme's background/chip ramp (see `amberBand`);
    /// identity for the light scheme and for hues outside the band. The neutral
    /// fallback ramp is not routed through here: it is near-grey by
    /// construction (`neutralRampChroma` 0.010), so its hue carries no warmth
    /// to correct.
    private static func amberedRampHue(_ hue: Double, scheme: ColorScheme) -> Double {
        guard scheme == .dark, amberBand.contains(hue) else { return hue }
        let span = amberBand.upperBound - amberBand.lowerBound
        let compression = (span - amberRotation) / span
        return amberBand.lowerBound + (hue - amberBand.lowerBound) * compression
    }

    private static func roleColor(_ role: (l: Double, c: Double), hue: Double) -> ColorMetrics.RGB {
        let c = OKLCH.clampedChroma(L: role.l, C: role.c, H: hue)
        return OKLCH.toSRGB(OKLCH.LCH(L: role.l, C: c, H: hue))
    }

    /// Scans non-primary candidates in weight order for one that can carry the
    /// accent role with its identity intact: hue-distinct and vivid to be
    /// eligible, then seeded from the cover's OWN observed L/C (not the
    /// recipe's fixed lightness — forcing a neon through the bold seed's
    /// L 0.57 yields olive) and contrast-enforced. A candidate whose enforced
    /// result drifts past the identity gate is skipped, not clamped: the next
    /// candidate gets a try, and with none left the caller keeps the
    /// primary-hue accent. Floors hold by construction (`enforcedAccent`).
    private static func promotedAccent(
        for signature: CoverSignature,
        primary: CoverSignature.HueCandidate,
        backgrounds: [ColorMetrics.RGB],
        chip: ColorMetrics.RGB
    ) -> ColorMetrics.RGB? {
        for candidate in signature.candidates.dropFirst() {
            let delta = abs(candidate.hue - primary.hue)
            let separation = min(delta, 360 - delta)
            guard separation >= promotionHueSeparation,
                candidate.chroma >= promotionChromaFloor,
                candidate.weight >= primary.weight * promotionWeightShare
            else { continue }

            let seedChroma = OKLCH.clampedChroma(
                L: candidate.lightness, C: candidate.chroma, H: candidate.hue)
            let seed = OKLCH.toSRGB(
                OKLCH.LCH(L: candidate.lightness, C: seedChroma, H: candidate.hue))
            let enforced = enforcedAccent(
                seed, hue: candidate.hue, backgrounds: backgrounds, chip: chip)

            let lch = OKLCH.fromSRGB(enforced)
            if abs(lch.L - candidate.lightness) <= promotionMaxLightnessDrift,
                lch.C >= promotionMinChroma
            {
                return enforced
            }
        }
        return nil
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
