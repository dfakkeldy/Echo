import WidgetKit
import SwiftUI
import AppIntents

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), title: "Book Title", isPlaying: false, progressFraction: 0.3, thumbnailData: nil)
    }

    // Helper to ensure image data isn't too large for the widget
    private func safelyDownsampledData(_ data: Data?) -> Data? {
        guard let data = data, let image = UIImage(data: data) else { return nil }
        // If the legacy image is too large, it crashes widget archival.
        // Discard it. The updated iOS app will sync a properly sized 60x60 image.
        if image.size.width > 100 || image.size.height > 100 {
            return nil
        }
        return data
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let defaults = UserDefaults(suiteName: "group.com.audiohd")
        let title = defaults?.string(forKey: "title") ?? "No track"
        let isPlaying = defaults?.bool(forKey: "isPlaying") ?? false
        let progressFraction = defaults?.double(forKey: "progressFraction") ?? 0.0
        let thumbnailData = safelyDownsampledData(defaults?.data(forKey: "thumbnailData"))
        
        let entry = SimpleEntry(date: Date(), title: title, isPlaying: isPlaying, progressFraction: progressFraction, thumbnailData: thumbnailData)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> ()) {
        let defaults = UserDefaults(suiteName: "group.com.audiohd")
        let title = defaults?.string(forKey: "title") ?? "No track"
        let isPlaying = defaults?.bool(forKey: "isPlaying") ?? false
        let progressFraction = defaults?.double(forKey: "progressFraction") ?? 0.0
        let thumbnailData = safelyDownsampledData(defaults?.data(forKey: "thumbnailData"))

        let entry = SimpleEntry(date: Date(), title: title, isPlaying: isPlaying, progressFraction: progressFraction, thumbnailData: thumbnailData)
        
        // Refresh periodically, but mostly we rely on reloadAllTimelines() when data changes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
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
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: isPlaying ? 100.0 : 0.0)
    }
}

struct AuDioHD_WidgetEntryView : View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var body: some View {
        ZStack {
            if let data = entry.thumbnailData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .padding(4)
            } else {
                Image(systemName: "music.note")
            }

            Circle()
                .stroke(.secondary.opacity(0.3), lineWidth: 4)

            Circle()
                .trim(from: 0, to: entry.progressFraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))

            GeometryReader { geo in
                let radius = geo.size.width / 2
                let angle = entry.progressFraction * 2 * .pi - .pi / 2
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .position(
                        x: radius + radius * CGFloat(cos(angle)),
                        y: radius + radius * CGFloat(sin(angle))
                    )
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "audiohd://"))
    }
}

struct AuDioHD_Widget: Widget {
    let kind: String = "AuDioHD_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            AuDioHD_WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AuDioHD")
        .description("Quick access to your current audiobook.")
        .supportedFamilies([.accessoryCircular])
    }
}
