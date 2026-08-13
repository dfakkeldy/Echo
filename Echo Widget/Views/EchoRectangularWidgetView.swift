// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

struct EchoRectangularWidgetView: View {
    let entry: SimpleEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 8) {
            EchoWidgetArtworkView(
                thumbnailData: entry.thumbnailData,
                presentation: .rectangular
            )
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.caption)
                    .bold()
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(entry.playbackStateText)
                    Spacer(minLength: 0)
                    Text(entry.progressPercentageText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.secondary.opacity(0.25))
                        Capsule()
                            .fill(progressColor)
                            .frame(width: geometry.size.width * entry.clampedProgress)
                            .widgetAccentable()
                    }
                }
                .frame(height: WatchProgressRingMetrics.rectangularGaugeHeight)
            }
        }
    }

    private var progressColor: Color {
        switch WidgetProgressAccentPolicy.style(
            accentHex: entry.artworkAccentColorHex,
            preservesExactCoverColor: renderingMode == .fullColor
        ) {
        case .systemTint:
            return .accentColor
        case .cover(let rgb):
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
    }
}
