// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SpeedCardView: View {
    @Environment(PlayerModel.self) private var model

    private let speeds: [Float] = SettingsManager.Defaults.speedPresets

    var body: some View {
        Button {
            cycleSpeed()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Speed", systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(format: "%.2f×", model.speed))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.teal)

                Text("tap to change")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 100)
            .background(.teal.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }

    private func cycleSpeed() {
        guard let currentIndex = speeds.firstIndex(of: model.speed) else {
            model.setSpeed(speeds[0])
            return
        }
        let next = speeds[(currentIndex + 1) % speeds.count]
        model.setSpeed(next)
    }
}
