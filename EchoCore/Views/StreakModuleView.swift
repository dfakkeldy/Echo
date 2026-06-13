import SwiftUI

/// Current listening streak from playback_event active days.
import os.log

struct StreakModuleView: View {
    @Environment(PlayerModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 140
    @State private var currentStreak: Int = 0
    @State private var longestStreak: Int = 0
    private let logger = Logger(category: "StreakModuleView")

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Streak", systemImage: "flame")
                .font(.caption)
                .foregroundStyle(.secondary)

            if currentStreak > 0 {
                Text("\(currentStreak) day\(currentStreak == 1 ? "" : "s")")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
                Text("Best: \(longestStreak) day\(longestStreak == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Text("Start listening")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: cardWidth)
        .background(.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await load() }
    }

    private func load() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            let overview = try await repo.fetchOverview()
            currentStreak = overview.streak.currentStreakDays
            longestStreak = overview.streak.longestStreakDays
        } catch {
            logger.error("Failed to load streak stats: \(error.localizedDescription)")
        }
    }
}
