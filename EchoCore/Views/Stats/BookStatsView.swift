import SwiftUI

/// Per-book stats: chapter coverage and listening totals.
import os.log

struct BookStatsView: View {
    @Environment(PlayerModel.self) private var model

    let bookID: String
    let bookTitle: String

    @State private var chapters: [ChapterCoverage] = []
    @State private var totalSegments: Int = 0
    @State private var totalDuration: TimeInterval = 0
    private let logger = Logger(category: "BookStatsView")

    var body: some View {
        List {
            Section("Total") {
                LabeledContent("Listening time", value: fmt(totalDuration))
                LabeledContent("Sessions", value: "\(totalSegments)")
            }

            if !chapters.isEmpty {
                Section("Chapter Coverage") {
                    ForEach(chapters) { ch in
                        HStack {
                            Text(ch.chapterTitle)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", ch.coveredFraction * 100))
                                .foregroundStyle(ch.coveredFraction > 0.5 ? .green : .secondary)
                            if ch.listenPassCount > 1 {
                                Text("×\(ch.listenPassCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(bookTitle)
        .task { await load() }
    }

    private func load() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            chapters = try await repo.fetchChapterCoverage(audiobookID: bookID)
            let segs = try await repo.fetchSegments(
                from: .distantPast, to: .distantFuture, audiobookID: bookID
            )
            totalSegments = segs.count
            totalDuration = segs.reduce(0) { $0 + $1.adjustedDuration }
        } catch {
            logger.error("Failed to load book stats: \(error.localizedDescription)")
        }
    }

    private func fmt(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
