import SwiftUI

struct ListeningProgressModuleView: View {
    @Environment(PlayerModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Progress", systemImage: "book")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Observes the coarse ~1 Hz percent, not per-tick currentPlaybackTime (§7.3).
            Text("\(model.bookProgressPercent)%")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.blue)

            Text("in \(model.currentTitle)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: cardWidth)
        .background(.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
