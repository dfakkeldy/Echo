import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Pure colour math shared by the cover-theme pipeline.
///
/// The metric core works on `RGB` (sRGB, 0…1 `Double`s) so it is fully
/// unit-testable without UIKit. Only the `Color`↔`RGB` bridge touches the
/// platform. WCAG luminance/contrast lives here; perceptual conversions
/// live in `OKLCH`.
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
