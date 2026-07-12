// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Platform-neutral RGB components used by the Watch app's SwiftUI color bridge.
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
