// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// MARK: - Flow Layout

/// A custom Layout that arranges subviews horizontally, wrapping to the next
/// line when they exceed the available width. Behaves like CSS flex-wrap.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += maxHeight + verticalSpacing
                maxHeight = 0
            }
            maxHeight = max(maxHeight, size.height)
            x += size.width + horizontalSpacing
        }

        return CGSize(width: width, height: y + maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            lineHeight = max(lineHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}

// MARK: - Word Cloud View

/// Renders a word cloud where word size and weight scale with frequency.
struct WordCloudView: View {
    let words: [WordFrequency]
    var maxWords: Int = 30

    private var topWords: [WordFrequency] {
        Array(words.prefix(maxWords))
    }

    private var maxCount: Int {
        topWords.first?.count ?? 1
    }

    var body: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
            ForEach(topWords) { word in
                Text(word.word)
                    .font(.system(size: fontSize(for: word.count)))
                    .fontWeight(fontWeight(for: word.count))
                    .foregroundStyle(color(for: word.count))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Scaling helpers

    private func fontSize(for count: Int) -> CGFloat {
        let fraction = CGFloat(count) / CGFloat(maxCount)
        return 10 + fraction * 18  // 10pt → 28pt
    }

    private func fontWeight(for count: Int) -> Font.Weight {
        let fraction = CGFloat(count) / CGFloat(maxCount)
        if fraction > 0.7 { return .bold }
        if fraction > 0.4 { return .semibold }
        if fraction > 0.2 { return .medium }
        return .regular
    }

    private func color(for count: Int) -> Color {
        let fraction = CGFloat(count) / CGFloat(maxCount)
        return .primary.opacity(0.4 + fraction * 0.6)
    }
}
