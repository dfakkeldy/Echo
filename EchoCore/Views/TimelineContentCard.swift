import SwiftUI

struct TimelineContentCard: View {
    let card: ContentCard
    let isEditing: Bool
    var projectedTime: Date? = nil
    var projectionSpeed: Double = 1.0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    icon
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(card.title)
                        .font(card.subtitle == nil ? .body : .subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if let timestamp = card.mediaTimestamp {
                        Text(formatHMS(timestamp))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let projected = projectedTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(RealTimeProjectionService().formatProjectedTime(projected, speed: projectionSpeed))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                if card.cardType == .playbackSession, let endedAt = card.endedAt {
                    let duration = endedAt.timeIntervalSince(card.realTimestamp)
                    Text("Listened \(formatDuration(duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if card.cardType == .plannedSession, let endedAt = card.endedAt {
                    Text("Scheduled: \(card.realTimestamp.formatted(date: .omitted, time: .shortened)) – \(endedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Private

    private var icon: some View {
        switch card.cardType {
        case .transcription:
            Image(systemName: "text.quote")
        case .bookmark:
            Image(systemName: "bookmark.fill")
        case .flashcard:
            Image(systemName: "rectangle.fill.on.rectangle.fill")
        case .note:
            Image(systemName: "note.text")
        case .playbackSession:
            Image(systemName: "play.fill")
        case .plannedSession:
            Image(systemName: "calendar")
        case .voiceMemo:
            Image(systemName: "mic.fill")
        case .chapterTransition:
            Image(systemName: "forward.end.fill")
        case .imageAsset:
            Image(systemName: "photo.fill")
        }
    }

    private var cardBackground: some View {
        switch card.cardType {
        case .transcription:
            Color.blue.opacity(0.08)
        case .bookmark:
            Color.orange.opacity(0.08)
        case .flashcard:
            Color.purple.opacity(0.08)
        case .note:
            Color.yellow.opacity(0.08)
        case .playbackSession:
            Color.green.opacity(0.06)
        case .plannedSession:
            Color.blue.opacity(0.06)
        case .voiceMemo:
            Color.red.opacity(0.08)
        case .chapterTransition:
            Color.gray.opacity(0.06)
        case .imageAsset:
            Color.teal.opacity(0.08)
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
