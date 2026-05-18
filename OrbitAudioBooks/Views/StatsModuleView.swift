import SwiftUI

struct StatsModuleView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Today", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let duration = model.durationSeconds, let position = model.durationSeconds.flatMap({ _ in model.currentPlaybackTime }) {
                let listenedToday = min(position, duration)
                Text(formatDuration(listenedToday))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)

                Text("of \(formatDuration(duration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 140)
        .background(.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
