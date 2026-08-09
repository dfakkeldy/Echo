// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Platform-neutral RGB components used by the Watch app and widget colour bridges.
nonisolated struct HexRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt64(digits, radix: 16) else { return nil }

        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }
}

nonisolated enum WidgetProgressAccentStyle: Equatable, Sendable {
    case systemTint
    case cover(HexRGB)
}

nonisolated enum WidgetProgressAccentPolicy {
    static func style(
        accentHex: String?,
        preservesExactCoverColor: Bool
    ) -> WidgetProgressAccentStyle {
        guard preservesExactCoverColor,
            let accentHex,
            let rgb = HexRGB(hex: accentHex)
        else {
            return .systemTint
        }
        return .cover(rgb)
    }
}

nonisolated enum WidgetCoverRampStyle: Equatable, Sendable {
    case systemBacking
    case ramp(top: HexRGB, bottom: HexRGB)
}

nonisolated enum WidgetCoverRampPolicy {
    /// Both ends or neither: a gradient drawn from one valid hex and one
    /// fallback is not the cover's ramp, it is a different colour that happens
    /// to start in the right place.
    ///
    /// Outside full colour the system flattens whatever the widget supplies, so
    /// the ramp yields to the calibrated container backing rather than spending
    /// the same grey twice.
    static func style(
        topHex: String?,
        bottomHex: String?,
        preservesExactCoverColor: Bool
    ) -> WidgetCoverRampStyle {
        guard preservesExactCoverColor,
            let topHex,
            let bottomHex,
            let top = HexRGB(hex: topHex),
            let bottom = HexRGB(hex: bottomHex)
        else {
            return .systemBacking
        }
        return .ramp(top: top, bottom: bottom)
    }
}
