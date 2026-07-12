// SPDX-License-Identifier: GPL-3.0-or-later
import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

struct Provider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 60

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(), title: "Book Title", isPlaying: false, progressFraction: 0.3,
            thumbnailData: nil, artworkAccentColorHex: "#FF8000")
    }

    // Helper to ensure image data isn't too large for the widget
    private func safelyDownsampledData(_ data: Data?) -> Data? {
        guard let data = data, let image = UIImage(data: data) else { return nil }

        let maxSize: CGFloat = 60
        if image.size.width > maxSize || image.size.height > maxSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize * 2.0,  // retina scale
            ]
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary)
            {
                return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.75)
            }
        }

        return data
    }

    private func currentEntry() -> SimpleEntry {
        let defaults = AppGroupDefaults.shared
        let title = defaults.string(forKey: "title") ?? "No track"
        let isPlaying = defaults.bool(forKey: "isPlaying")
        let progressFraction = defaults.double(forKey: "totalProgressFraction")
        let thumbnailData = safelyDownsampledData(defaults.data(forKey: "thumbnailData"))
        let artworkAccentColorHex = defaults.string(forKey: "artworkAccentColorHex")

        return SimpleEntry(
            date: Date(), title: title, isPlaying: isPlaying, progressFraction: progressFraction,
            thumbnailData: thumbnailData, artworkAccentColorHex: artworkAccentColorHex)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Date().addingTimeInterval(Self.refreshInterval)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let title: String
    let isPlaying: Bool
    let progressFraction: Double
    let thumbnailData: Data?
    let artworkAccentColorHex: String?

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: isPlaying ? 100.0 : 0.0)
    }
}

struct Echo_WidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        let progress = min(1, max(0, entry.progressFraction))

        ZStack {
            if let data = entry.thumbnailData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(.circle)
                    .padding(4)
            } else {
                Image(systemName: "music.note")
            }

            Circle()
                .stroke(.secondary.opacity(0.3), lineWidth: 4)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()

            GeometryReader { geo in
                let radius = geo.size.width / 2
                let angle = progress * 2 * .pi - .pi / 2
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .position(
                        x: radius + radius * CGFloat(cos(angle)),
                        y: radius + radius * CGFloat(sin(angle))
                    )
                    .widgetAccentable()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "echoaudio://play"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(
            "\(entry.isPlaying ? String(localized: "Playing") : String(localized: "Paused")), "
                + progress.formatted(.percent.precision(.fractionLength(0))))
    }
}

struct Echo_Widget: Widget {
    let kind: String = "Echo_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            Echo_WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Echo")
        .description("Quick access to your current audiobook.")
        .supportedFamilies([.accessoryCircular])
    }
}
