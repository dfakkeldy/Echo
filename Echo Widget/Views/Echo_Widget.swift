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

struct Echo_Widget: Widget {
    let kind: String = "Echo_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            Echo_WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Echo")
        .description("Current audiobook and progress at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
