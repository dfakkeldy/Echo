// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WidgetKit

#if DEBUG
    extension SimpleEntry {
        static let previewPaused = SimpleEntry(
            date: .now,
            title: "A Paused Book",
            isPlaying: false,
            progressFraction: 0,
            thumbnailData: nil,
            artworkAccentColorHex: nil,
            coverRampTopHex: nil,
            coverRampBottomHex: nil
        )

        static let previewPlaying = SimpleEntry(
            date: .now,
            title: "The Current Book",
            isPlaying: true,
            progressFraction: 0.42,
            thumbnailData: nil,
            artworkAccentColorHex: "#FF8000",
            coverRampTopHex: "#3A2A12",
            coverRampBottomHex: "#2C1F0D"
        )

        static let previewComplete = SimpleEntry(
            date: .now,
            title: "A Finished Book",
            isPlaying: false,
            progressFraction: 1,
            thumbnailData: nil,
            artworkAccentColorHex: "#GG0000",
            coverRampTopHex: "#GG0000",
            coverRampBottomHex: "#2C1F0D"
        )
    }

    #Preview("Circular", as: .accessoryCircular) {
        Echo_Widget()
    } timeline: {
        SimpleEntry.previewPaused
        SimpleEntry.previewPlaying
        SimpleEntry.previewComplete
    }

    #Preview("Rectangular", as: .accessoryRectangular) {
        Echo_Widget()
    } timeline: {
        SimpleEntry.previewPaused
        SimpleEntry.previewPlaying
        SimpleEntry.previewComplete
    }

    #Preview("Rectangular full colour") {
        EchoRectangularWidgetView(entry: .previewPlaying)
            .environment(\.widgetRenderingMode, .fullColor)
            .frame(width: 170, height: 60)
    }

    #Preview("Rectangular accented") {
        EchoRectangularWidgetView(entry: .previewPlaying)
            .environment(\.widgetRenderingMode, .accented)
            .frame(width: 170, height: 60)
    }

    #Preview("Rectangular vibrant") {
        EchoRectangularWidgetView(entry: .previewComplete)
            .environment(\.widgetRenderingMode, .vibrant)
            .frame(width: 170, height: 60)
    }

    #Preview("Rectangular full-colour fallback") {
        EchoRectangularWidgetView(entry: .previewPaused)
            .environment(\.widgetRenderingMode, .fullColor)
            .frame(width: 170, height: 60)
    }
#endif
