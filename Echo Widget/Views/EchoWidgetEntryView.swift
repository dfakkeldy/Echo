// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

struct Echo_WidgetEntryView: View {
    let entry: SimpleEntry

    @Environment(\.widgetFamily) private var widgetFamily

    var body: some View {
        Group {
            if widgetFamily == .accessoryRectangular {
                EchoRectangularWidgetView(entry: entry)
            } else {
                EchoCircularWidgetView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "echoaudio://play"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.accessibilityValue)
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
