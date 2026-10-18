// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Pure colour math shared by the cover-theme pipeline.
///
/// The metric core works on `RGB` (sRGB, 0…1 `Double`s) so it is fully
/// unit-testable without UIKit. Only the `Color`↔`RGB` bridge touches the
/// platform. WCAG luminance/contrast lives here; perceptual conversions
/// live in `OKLCH`.
nonisolated enum ColorMetrics {

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

    /// Creates a SwiftUI `Color` from an sRGB triple. Platform-neutral — the
    /// initializer is pure SwiftUI — so it sits outside the gate `rgb(_:)`
    /// needs. It lived inside that gate until macOS started consuming the
    /// pipeline, which was proximity, not a dependency.
    static func color(_ c: RGB) -> Color {
        Color(red: c.r, green: c.g, blue: c.b)
    }

    #if canImport(UIKit)
        /// Extracts sRGB components from a SwiftUI `Color`.
        static func rgb(_ color: Color) -> RGB {
            let ui = UIColor(color)
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            return RGB(r: Double(r), g: Double(g), b: Double(b))
        }
    #elseif canImport(AppKit)
        /// AppKit twin of the UIKit bridge above.
        ///
        /// The colour-space conversion is mandatory, not defensive:
        /// `NSColor.redComponent` and friends raise unless the receiver is
        /// already in an RGB space, and the one colour this is called with —
        /// `Color.accentColor` — is a catalog colour that is not. Converting to
        /// sRGB explicitly also keeps the Mac's reading identical to the
        /// phone's on a Display P3 screen, which is what makes the two
        /// platforms resolve the same accent for the same cover.
        static func rgb(_ color: Color) -> RGB {
            // `.sRGB` then `.deviceRGB`: the second is a belt-and-braces path
            // for a colour whose profile refuses the first. Both failing means
            // the brand colour is unreadable, which only affects the neutral
            // fallback's seed hue — `enforcedAccent` still guarantees the
            // contrast floors from whatever seed it gets.
            let ns = NSColor(color)
            guard let rgb = ns.usingColorSpace(.sRGB) ?? ns.usingColorSpace(.deviceRGB) else {
                return RGB(r: 0, g: 0, b: 0)
            }
            return RGB(
                r: Double(rgb.redComponent),
                g: Double(rgb.greenComponent),
                b: Double(rgb.blueComponent)
            )
        }
    #endif
}
