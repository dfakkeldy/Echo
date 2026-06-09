import SwiftUI

/// Rescues an artwork-derived accent that would be illegible against the
/// player surface, using a progressive A→B→C ladder. Operates entirely on
/// `ColorMetrics.RGB` so it is pure and unit-testable.
enum AccentSafetyNet {

    /// Which rung of the ladder produced the result (for debug + tests).
    enum Tier: Equatable { case original, nudged, repicked, brand }

    struct Resolution: Equatable {
        let color: ColorMetrics.RGB
        let tier: Tier
    }

    /// Two stacked `.ultraThinMaterial` layers pull the surface strongly
    /// toward the scheme base; only a faint artwork tint survives.
    static let materialWeight: Double = 0.70

    /// Rescues `rawAccent` if it's illegible against `surface`, escalating
    /// through A (nudge) → B (re-pick candidate cover hue) → C (nudged brand).
    static func resolve(rawAccent: ColorMetrics.RGB,
                        candidates: [ColorMetrics.RGB],
                        surface: ColorMetrics.RGB,
                        brand: ColorMetrics.RGB) -> Resolution {
        // Gate — most covers exit here, byte-for-byte unchanged.
        if ColorMetrics.isLegible(rawAccent, on: surface) {
            return Resolution(color: rawAccent, tier: .original)
        }

        // Tier A — nudge the winner in place.
        let a = ColorMetrics.nudged(rawAccent, toClear: ColorMetrics.contrastFloor, against: surface)
        if a.lightnessShift <= ColorMetrics.distortionBudget {
            return Resolution(color: a.color, tier: .nudged)
        }

        // Tier B — fall to the next cover hue that's already (or nearly) safe.
        for candidate in candidates where candidate != rawAccent {
            if ColorMetrics.isLegible(candidate, on: surface) {
                return Resolution(color: candidate, tier: .repicked)
            }
            let b = ColorMetrics.nudged(candidate, toClear: ColorMetrics.contrastFloor, against: surface)
            if b.lightnessShift <= ColorMetrics.distortionBudget {
                return Resolution(color: b.color, tier: .repicked)
            }
        }

        // Tier C — brand tint, nudged to clear the floor. Always legible.
        let c = ColorMetrics.nudged(brand, toClear: ColorMetrics.contrastFloor, against: surface)
        return Resolution(color: c.color, tier: .brand)
    }

    /// Estimated colour behind the controls: the cover's average background
    /// colour blended toward the scheme base by `materialWeight`.
    static func representativeSurface(background: [ColorMetrics.RGB],
                                      scheme: ColorScheme) -> ColorMetrics.RGB {
        let base: ColorMetrics.RGB = scheme == .dark
            ? ColorMetrics.RGB(r: 0.11, g: 0.11, b: 0.12)   // ≈ systemBackground (dark)
            : ColorMetrics.RGB(r: 0.95, g: 0.95, b: 0.94)   // ≈ systemBackground (light)
        guard !background.isEmpty else { return base }
        let n = Double(background.count)
        let avg = ColorMetrics.RGB(
            r: background.map(\.r).reduce(0, +) / n,
            g: background.map(\.g).reduce(0, +) / n,
            b: background.map(\.b).reduce(0, +) / n
        )
        let w = materialWeight
        return ColorMetrics.RGB(
            r: avg.r * (1 - w) + base.r * w,
            g: avg.g * (1 - w) + base.g * w,
            b: avg.b * (1 - w) + base.b * w
        )
    }
}
