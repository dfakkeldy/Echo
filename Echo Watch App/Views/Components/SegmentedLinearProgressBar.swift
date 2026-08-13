// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Whole-book linear progress bar segmented at chapter/track boundaries.
/// Falls back to a single capsule when the book has no interior boundaries or
/// too many to render legibly at the available width.
struct SegmentedLinearProgressBar: View {
    /// Whole-book progress fraction, 0...1.
    let progress: Double
    /// Raw boundary fractions from the iPhone (sanitized per available width).
    let rawBoundaries: [Double]
    let tint: Color
    let animationSuppressed: Bool

    private static let height: CGFloat = 3

    var body: some View {
        // GeometryReader is required here: segment capsule widths are
        // proportional shares of the actual rail width (same pattern as the
        // iOS BookProgressTrack).
        GeometryReader { geo in
            let segments = BookProgressSegmentMetrics.linearSegments(
                rawBoundaries: rawBoundaries,
                progress: progress,
                availableWidth: geo.size.width
            )
            let gap = BookProgressSegmentMetrics.linearGapWidth
            let usableWidth = max(0, geo.size.width - gap * CGFloat(segments.count - 1))

            HStack(spacing: gap) {
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(tint)
                            .frame(width: usableWidth * segment.span * segment.fill)
                    }
                    .frame(width: usableWidth * segment.span)
                }
            }
        }
        .frame(height: Self.height)
        .animation(animationSuppressed ? nil : .linear(duration: 0.5), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Book progress")
        .accessibilityValue("\(Int((min(1, max(0, progress)) * 100).rounded())) percent")
    }
}
