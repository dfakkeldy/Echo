// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Transient crown-volume HUD. Echo's crown volume adjusts the iPhone app's
/// output gain (not system volume), so the system volume overlay never shows —
/// this pill is the visual feedback while the crown turns, faded out by the
/// caller shortly after the last rotation.
struct VolumeIndicatorView: View {
    /// Normalized gain position, 0...1 across the −40…+9 dB range.
    let fraction: Double
    let tint: Color

    private static let barWidth: CGFloat = 64
    private static let barHeight: CGFloat = 4

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.3.fill", variableValue: fraction)
                .font(.footnote)
                .foregroundStyle(.white)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: Self.barWidth, height: Self.barHeight)

                Capsule()
                    .fill(tint)
                    .frame(width: Self.barWidth * fraction, height: Self.barHeight)

                // Notch marking the neutral 0 dB position within the gain range.
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1, height: Self.barHeight * 2)
                    .offset(x: Self.barWidth * WatchCrownVolume.neutralFraction)
            }
            .frame(width: Self.barWidth, height: Self.barHeight * 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.linear(duration: 0.08), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
