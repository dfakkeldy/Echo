import SwiftUI

struct ListeningProgressModuleView: View {
    @Environment(PlayerModel.self) private var model

    private var progressFraction: Double {
        guard let duration = model.durationSeconds, duration > 0 else { return 0 }
        return min(1.0, model.currentPlaybackTime / duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Progress", systemImage: "book")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(Int(progressFraction * 100))%")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.blue)

            Text("in \(model.currentTitle)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 140)
        .background(.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
