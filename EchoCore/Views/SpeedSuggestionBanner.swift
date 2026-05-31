import SwiftUI

struct SpeedSuggestionBanner: View {
    @Environment(PlayerModel.self) private var model

    private let projection = RealTimeProjectionService()

    var body: some View {
        if let suggestion = currentSuggestion {
            switch suggestion.scenario {
            case .onTrack:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(suggestion.description)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.green.opacity(0.1))

            case .needAdjustment:
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(suggestion.description)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.1))

            case .insufficient:
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(suggestion.description)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.red.opacity(0.1))
            }
        }
    }

    private var currentSuggestion: SpeedSuggestion? {
        guard let duration = model.durationSeconds, duration > 0 else { return nil }
        return projection.estimateCompletion(
            currentPosition: model.currentPlaybackTime,
            totalDuration: duration,
            currentSpeed: Double(model.speed)
        )
    }
}
