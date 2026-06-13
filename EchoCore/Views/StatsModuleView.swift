import SwiftUI

/// Today's total listening time, queried from playback_event via StatsRepository.
import os.log

struct StatsModuleView: View {
    private let logger = Logger(category: "StatsModuleView")
    @Environment(PlayerModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 140
    @State private var todayDuration: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Today", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

            if todayDuration > 0 {
                Text(formatDuration(todayDuration))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
                Text("listened")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Text("No listening yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: cardWidth)
        .background(.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await loadToday() }
    }

    private func loadToday() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            let overview = try await repo.fetchOverview()
            todayDuration = overview.todayDuration
        } catch {
            logger.error("Failed to load today stats: \(error.localizedDescription)")
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
