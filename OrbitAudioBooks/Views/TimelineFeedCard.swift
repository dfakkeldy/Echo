import SwiftUI

/// A Twitter-style card for the audiobook timeline feed.
/// Displays an icon, title, optional subtitle, and media timestamp
/// with subtle color coding per content type.
struct TimelineFeedCard: View {
    let card: ContentCard
    let isCurrentItem: Bool
    let totalDuration: TimeInterval

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Leading icon
            iconView
                .font(.title3)
                .frame(width: 28, height: 28)
                .padding(.top, 10)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if let ts = card.mediaTimestamp {
                        Text(formatHMS(ts))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                // Progress bar for the current item
                if isCurrentItem, let ts = card.mediaTimestamp, totalDuration > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.blue)
                                .frame(width: geo.size.width * CGFloat(ts / totalDuration), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(cardBackground)
        .overlay(alignment: .leading) {
            if isCurrentItem {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.blue)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - Private

    private var iconView: some View {
        let (name, color) = iconFor(card.cardType)
        return Image(systemName: name)
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var cardBackground: some View {
        if isCurrentItem {
            return Color.blue.opacity(0.06)
        }
        switch card.cardType {
        case .transcription:   return Color.blue.opacity(0.04)
        case .bookmark:        return Color.orange.opacity(0.04)
        case .flashcard:       return Color.purple.opacity(0.04)
        case .note:            return Color.yellow.opacity(0.04)
        case .playbackSession: return Color.green.opacity(0.04)
        case .plannedSession:  return Color.indigo.opacity(0.04)
        case .voiceMemo:       return Color.red.opacity(0.04)
        case .chapterTransition: return Color.gray.opacity(0.04)
        }
    }

    private func iconFor(_ type: ContentCardType) -> (name: String, color: Color) {
        switch type {
        case .transcription:   return ("text.quote", .blue)
        case .bookmark:        return ("bookmark.fill", .orange)
        case .flashcard:       return ("rectangle.fill.on.rectangle.fill", .purple)
        case .note:            return ("note.text", .yellow)
        case .playbackSession: return ("play.fill", .green)
        case .plannedSession:  return ("calendar", .indigo)
        case .voiceMemo:       return ("mic.fill", .red)
        case .chapterTransition: return ("forward.end.fill", .gray)
        }
    }
}
