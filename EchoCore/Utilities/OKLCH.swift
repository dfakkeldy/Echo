import Foundation

/// Conversions between sRGB and the OKLCH cylindrical form of OKLab.
///
/// OKLab lightness is perceptually uniform across hues — unlike HSL, where
/// "lightness 0.55" is near-white for yellow but dark for blue. The tone
/// recipes in `CoverThemeBuilder` rely on this to guarantee contrast for
/// every hue.
///
/// Reference: Björn Ottosson, "A perceptual color space for image
/// processing" (bottosson.github.io/posts/oklab). Matrix constants are his
/// published sRGB D65 values.
enum OKLCH {

    struct LCH: Equatable {
        var L: Double   // 0…1 perceptual lightness
        var C: Double   // chroma; ≲0.37 inside sRGB
        var H: Double   // hue angle, degrees, 0…<360
    }

    // MARK: - Public API

    static func fromSRGB(_ rgb: ColorMetrics.RGB) -> LCH {
        let (L, a, b) = oklab(fromSRGB: rgb)
        let c = (a * a + b * b).squareRoot()
        var h = atan2(b, a) * 180.0 / .pi
        if h < 0 { h += 360 }
        return LCH(L: L, C: c, H: h)
    }

    /// Converts to sRGB, clamping each channel into 0…1. Callers that need
    /// gamut fidelity should reduce chroma via `clampedChroma` first.
    static func toSRGB(_ lch: LCH) -> ColorMetrics.RGB {
        let lin = linearSRGB(lch)
        return ColorMetrics.RGB(
            r: delinearize(min(max(lin.r, 0), 1)),
            g: delinearize(min(max(lin.g, 0), 1)),
            b: delinearize(min(max(lin.b, 0), 1))
        )
    }

    /// Largest chroma ≤ `C` that stays inside sRGB at the given L and H.
    static func clampedChroma(L: Double, C: Double, H: Double) -> Double {
        if inGamut(LCH(L: L, C: C, H: H)) { return C }
        var lo = 0.0
        var hi = C
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if inGamut(LCH(L: L, C: mid, H: H)) { lo = mid } else { hi = mid }
        }
        return lo
    }

    // MARK: - Internals

    private static let gamutTolerance = 1e-4

    private static func inGamut(_ lch: LCH) -> Bool {
        let lin = linearSRGB(lch)
        let lo = -gamutTolerance
        let hi = 1 + gamutTolerance
        return lin.r >= lo && lin.r <= hi
            && lin.g >= lo && lin.g <= hi
            && lin.b >= lo && lin.b <= hi
    }

    private static func linearSRGB(_ lch: LCH) -> (r: Double, g: Double, b: Double) {
        let hRad = lch.H * .pi / 180.0
        let a = lch.C * cos(hRad)
        let b = lch.C * sin(hRad)

        let lp = lch.L + 0.3963377774 * a + 0.2158037573 * b
        let mp = lch.L - 0.1055613458 * a - 0.0638541728 * b
        let sp = lch.L - 0.0894841775 * a - 1.2914855480 * b

        let l = lp * lp * lp
        let m = mp * mp * mp
        let s = sp * sp * sp

        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    private static func oklab(fromSRGB rgb: ColorMetrics.RGB) -> (L: Double, a: Double, b: Double) {
        let r = linearize(rgb.r)
        let g = linearize(rgb.g)
        let b = linearize(rgb.b)

        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let lp = cbrt(l)
        let mp = cbrt(m)
        let sp = cbrt(s)

        return (
            0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp,
            1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp,
            0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp
        )
    }

    private static func linearize(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func delinearize(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }
}
