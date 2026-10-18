// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import SwiftUI

/// Full-screen tonal ramp from the current cover's theme: a pale wash in
/// light mode, an immersive deep room in dark mode. Replaces the old
/// three-hue gradient + material stack (spec §5) — one designed hue with
/// tonal depth instead of a pastel soup.
struct AdaptiveBackground: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = model.coverTheme
        LinearGradient(
            colors: [theme.backgroundTop, theme.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay {
            // Wash grain: mid-grey noise under `.overlay` blending reads as
            // paper texture on the pale wash and breaks up the smooth-gradient
            // banding OLED panels show in the deep room (hence the stronger
            // dark opacity). Deviations this small move the wash's luminance
            // well under a percent, so the contrast floors are untouched.
            if let tile = WashGrain.tile {
                Image(decorative: tile, scale: 2)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(colorScheme == .dark ? 0.06 : 0.035)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }
}

/// One seeded noise tile, generated once per process. Deterministic by
/// design: the wash must look identical across launches and screenshots,
/// so the generator is a fixed xorshift* sequence, not `random()`.
nonisolated enum WashGrain {
    static let tile: CGImage? = makeTile()

    /// Grey values stay centred on 128 (a no-op under `.overlay` blending)
    /// inside `midBand`, so the grain modulates the wash without shifting
    /// its average tone.
    static let midBand: ClosedRange<UInt8> = 96...159
    static let tileSize = 96

    static func makeTile(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> CGImage? {
        var state = seed
        func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
        let span = UInt64(midBand.upperBound - midBand.lowerBound) + 1
        guard
            let context = CGContext(
                data: nil,
                width: tileSize,
                height: tileSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ),
            let buffer = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let bytesPerRow = context.bytesPerRow
        for y in 0..<tileSize {
            for x in 0..<tileSize {
                buffer[y * bytesPerRow + x] = midBand.lowerBound + UInt8(next() % span)
            }
        }
        return context.makeImage()
    }
}
