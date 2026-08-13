// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

struct Echo_WidgetEntryView: View {
    let entry: SimpleEntry

    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if widgetFamily == .accessoryRectangular {
                EchoRectangularWidgetView(entry: entry)
            } else {
                EchoCircularWidgetView(entry: entry)
            }
        }
        .containerBackground(for: .widget) { coverRamp }
        .widgetURL(URL(string: "echoaudio://play"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.accessibilityValue)
    }

    /// The cover's room behind the complication, falling back to the container
    /// backing the system already calibrates for the face it is drawn on.
    @ViewBuilder
    private var coverRamp: some View {
        switch WidgetCoverRampPolicy.style(
            topHex: entry.coverRampTopHex,
            bottomHex: entry.coverRampBottomHex,
            preservesExactCoverColor: renderingMode == .fullColor
        ) {
        case .systemBacking:
            Rectangle().fill(.fill.tertiary)
        case .ramp(let top, let bottom):
            LinearGradient(
                colors: [
                    Color(red: top.red, green: top.green, blue: top.blue),
                    Color(red: bottom.red, green: bottom.green, blue: bottom.blue),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

extension SimpleEntry {
    var clampedProgress: Double {
        guard progressFraction.isFinite else { return 0 }
        return min(1, max(0, progressFraction))
    }

    var playbackStateText: String {
        isPlaying ? String(localized: "Playing") : String(localized: "Paused")
    }

    var progressPercentageText: String {
        clampedProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    var accessibilityValue: String {
        "\(playbackStateText), \(progressPercentageText)"
    }
}
