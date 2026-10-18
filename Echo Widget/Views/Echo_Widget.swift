// SPDX-License-Identifier: GPL-3.0-or-later
import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

struct Provider: TimelineProvider {
    /// Safety-net re-run interval while paused (or unprojectable). Real
    /// changes arrive as app-driven `reloadTimelines` calls from the watch
    /// app; while playing, the timeline itself carries projected entries.
    /// The previous 60 s ask was far over WidgetKit's daily refresh budget,
    /// so the system silently throttled it — one root of the frozen card.
    private static let idleRefreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(), title: "Book Title", isPlaying: false, progressFraction: 0.3,
            thumbnailData: nil, artworkAccentColorHex: "#FF8000",
            coverRampTopHex: "#3A2A12", coverRampBottomHex: "#2C1F0D")
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

    /// Timeline entries for `dates`, sharing one read of the app-group
    /// snapshot. Each entry's progress is the wall-clock projection at that
    /// entry's date (`WatchWidgetProgressProjection`), so the bar keeps
    /// moving between data deliveries instead of freezing at the last write.
    private func entries(at dates: [Date], projection: WatchWidgetProgressProjection)
        -> [SimpleEntry]
    {
        let defaults = AppGroupDefaults.shared
        let title = defaults.string(forKey: "title") ?? "No track"
        let thumbnailData = safelyDownsampledData(defaults.data(forKey: "thumbnailData"))
        let artworkAccentColorHex = defaults.string(forKey: "artworkAccentColorHex")
        let coverRampTopHex = defaults.string(forKey: "coverRampTopHex")
        let coverRampBottomHex = defaults.string(forKey: "coverRampBottomHex")

        return dates.map { date in
            SimpleEntry(
                date: date, title: title, isPlaying: projection.isPlaying,
                progressFraction: projection.fraction(at: date),
                thumbnailData: thumbnailData, artworkAccentColorHex: artworkAccentColorHex,
                coverRampTopHex: coverRampTopHex,
                coverRampBottomHex: coverRampBottomHex)
        }
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        let now = Date()
        let projection = WatchWidgetProgressProjection.read(from: AppGroupDefaults.shared)
        completion(entries(at: [now], projection: projection)[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let now = Date()
        let projection = WatchWidgetProgressProjection.read(from: AppGroupDefaults.shared)
        let timelineEntries = entries(
            at: projection.timelineDates(startingAt: now), projection: projection)
        // Playing: re-run when the projected entries run out — the provider
        // re-anchors from defaults and keeps going, freezing only past the
        // projection's trust horizon. Paused (single entry): app-driven
        // reloads deliver real changes; the long interval is a safety net.
        let policy: TimelineReloadPolicy =
            timelineEntries.count > 1
            ? .atEnd : .after(now.addingTimeInterval(Self.idleRefreshInterval))
        completion(Timeline(entries: timelineEntries, policy: policy))
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let title: String
    let isPlaying: Bool
    let progressFraction: Double
    let thumbnailData: Data?
    let artworkAccentColorHex: String?
    /// Ends of the cover ramp, written into the app group by the Watch app when
    /// a state reply lands. Nil for a neutral cover.
    let coverRampTopHex: String?
    let coverRampBottomHex: String?

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
