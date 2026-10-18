// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

struct EchoCircularWidgetView: View {
    let entry: SimpleEntry

    var body: some View {
        ZStack {
            EchoWidgetArtworkView(
                thumbnailData: entry.thumbnailData,
                presentation: .circular
            )
            .clipShape(.circle)
            .padding(WatchProgressRingMetrics.complicationArtworkPadding)

            ZStack {
                Circle()
                    .stroke(
                        .secondary.opacity(0.3),
                        lineWidth: WatchProgressRingMetrics.complicationLineWidth
                    )

                Circle()
                    .trim(from: 0, to: entry.clampedProgress)
                    .stroke(
                        .tint,
                        style: StrokeStyle(
                            lineWidth: WatchProgressRingMetrics.complicationLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()

                GeometryReader { geometry in
                    let radius = min(geometry.size.width, geometry.size.height) / 2
                    let angle = entry.clampedProgress * 2 * .pi - .pi / 2
                    Circle()
                        .fill(.tint)
                        .frame(
                            width: WatchProgressRingMetrics.complicationMarkerDiameter,
                            height: WatchProgressRingMetrics.complicationMarkerDiameter
                        )
                        .position(
                            x: geometry.size.width / 2 + radius * CGFloat(cos(angle)),
                            y: geometry.size.height / 2 + radius * CGFloat(sin(angle))
                        )
                        .widgetAccentable()
                }
            }
            .padding(WatchProgressRingMetrics.complicationInset)
        }
    }
}
