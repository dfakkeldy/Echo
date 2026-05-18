import SwiftUI

struct ChapterTimeBlockView: View {
    let title: String
    let chapterIndex: Int
    let chapterCount: Int
    let startSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let totalBookDuration: TimeInterval
    let isCurrentChapter: Bool
    let isPlayed: Bool

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(barColor)
                .frame(width: barWidth, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "Chapter \(chapterIndex + 1)" : title)
                    .font(.caption)
                    .fontWeight(isCurrentChapter ? .bold : .regular)
                    .lineLimit(1)

                Text(formatHMS(durationSeconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isPlayed ? 0.5 : 1.0)
        .contentShape(Rectangle())
    }

    private var barColor: Color {
        if isCurrentChapter { return .blue }
        if isPlayed { return .gray }
        return .secondary.opacity(0.3)
    }

    private var barWidth: CGFloat {
        let fraction = durationSeconds / max(totalBookDuration, 1)
        return max(4, CGFloat(fraction) * 200)
    }
}
