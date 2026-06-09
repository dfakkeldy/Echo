import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Pure colour math for the accent contrast safety net.
///
/// The metric core works on `RGB` (sRGB, 0…1 `Double`s) so it is fully
/// unit-testable without UIKit. Only the `Color`↔`RGB` bridge touches the
/// platform.
enum ColorMetrics {

    /// sRGB triple, components in 0…1.
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    // MARK: - WCAG relative luminance + contrast

    /// Returns the relative luminance of an sRGB colour per WCAG 2.1, using the
    /// standard linearization and weighting coefficients.
    static func relativeLuminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// Returns the WCAG 2.1 contrast ratio between `a` and `b`.
    /// Symmetric — ordering doesn't matter.
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    // MARK: - Tunable constants
    // Tuned from a 5-cover sample. Bias toward leaving accents untouched;
    // revisit as the library grows.

    /// WCAG ratio that clears the luminance gate on its own.
    static let luminanceGate: Double = 2.4
    /// ΔE76 that clears the chroma gate on its own.
    static let chromaGate: Double = 52.0
    /// Minimum WCAG ratio a rescued accent must reach (UI-control grade).
    static let contrastFloor: Double = 3.0
    /// Largest HSL lightness shift Tier A may apply before escalating to B.
    static let distortionBudget: Double = 0.22

    // MARK: - CIELAB + ΔE76

    /// Converts an sRGB colour to CIE L*a*b* (D65 illuminant).
    static func lab(_ c: RGB) -> (L: Double, a: Double, b: Double) {
        func lin(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.r), g = lin(c.g), bl = lin(c.b)
        var x = r * 0.4124 + g * 0.3576 + bl * 0.1805
        let y = r * 0.2126 + g * 0.7152 + bl * 0.0722
        var z = r * 0.0193 + g * 0.1192 + bl * 0.9505
        x /= 0.95047
        z /= 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Returns the CIE76 (ΔE*₇₆) Euclidean distance between two sRGB colours.
    static func deltaE76(_ a: RGB, _ b: RGB) -> Double {
        let la = lab(a), lb = lab(b)
        let dL = la.L - lb.L
        let dA = la.a - lb.a
        let dB = la.b - lb.b
        return (dL * dL + dA * dA + dB * dB).squareRoot()
    }

    // MARK: - Two-gate legibility (the rescue trigger)

    /// An accent is legible if it clears EITHER the luminance gate OR the
    /// chroma gate against `surface`. Failing both = the "invisible" corner.
    static func isLegible(_ accent: RGB, on surface: RGB) -> Bool {
        contrastRatio(accent, surface) >= luminanceGate
            || deltaE76(accent, surface) >= chromaGate
    }

    // MARK: - HSL conversions

    /// Converts an sRGB colour to HSL (all components 0…1).
    static func toHSL(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let mx = max(c.r, max(c.g, c.b))
        let mn = min(c.r, min(c.g, c.b))
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 0.0001 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == c.r { h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    /// Creates an sRGB colour from HSL (all components 0…1).
    static func fromHSL(h: Double, s: Double, l: Double) -> RGB {
        guard s > 0.0001 else { return RGB(r: l, g: l, b: l) }
        func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return RGB(r: hue2rgb(p, q, h + 1.0 / 3),
                   g: hue2rgb(p, q, h),
                   b: hue2rgb(p, q, h - 1.0 / 3))
    }

    // MARK: - Lightness nudge

    /// Moves lightness (hue + saturation fixed) until `floor` contrast is met
    /// against `surface`, or a bound is hit. Darkens on a light surface,
    /// lightens on a dark one. Returns the result and the |Δlightness| moved.
    static func nudged(_ color: RGB,
                       toClear floor: Double,
                       against surface: RGB) -> (color: RGB, lightnessShift: Double) {
        if contrastRatio(color, surface) >= floor { return (color, 0) }
        let hsl = toHSL(color)
        let step = relativeLuminance(surface) > 0.5 ? -0.02 : 0.02   // darken on light
        var l = hsl.l
        var guardCount = 0
        while guardCount < 60 {
            l = min(max(l + step, 0), 1)
            let candidate = fromHSL(h: hsl.h, s: hsl.s, l: l)
            if contrastRatio(candidate, surface) >= floor {
                return (candidate, abs(hsl.l - l))
            }
            if l == 0 || l == 1 { break }     // hit the bound
            guardCount += 1
        }
        let boundL: Double = step < 0 ? 0 : 1
        return (fromHSL(h: hsl.h, s: hsl.s, l: boundL), abs(hsl.l - boundL))
    }

    // MARK: - Color bridge (the only platform-touching part)

    #if canImport(UIKit)
    /// Extracts sRGB components from a SwiftUI `Color`.
    static func rgb(_ color: Color) -> RGB {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: Double(r), g: Double(g), b: Double(b))
    }

    /// Creates a SwiftUI `Color` from an sRGB triple.
    static func color(_ c: RGB) -> Color {
        Color(red: c.r, green: c.g, blue: c.b)
    }
    #endif
}
