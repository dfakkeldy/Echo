// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The progress ring around the center transport button, segmented at
/// chapter/track boundaries when whole-book boundaries are provided. With no
/// boundaries (chapter mode, single-chapter books, or too many chapters) it
/// renders the classic unsegmented ring.
struct SegmentedProgressRing: View {
    /// Progress fraction, 0...1, of whichever source the ring tracks.
    let progress: Double
    /// Raw whole-book boundary fractions; pass `[]` for an unsegmented ring.
    let rawBoundaries: [Double]
    let tint: Color
    let size: CGFloat
    let animationSuppressed: Bool

    private static let lineWidth: CGFloat = 4

    var body: some View {
        let segments = BookProgressSegmentMetrics.ringSegments(
            rawBoundaries: rawBoundaries, progress: progress)
        let isSegmented = segments.count > 1
        let gap = isSegmented ? BookProgressSegmentMetrics.ringGapFraction : 0
        // Round caps on a segmented ring would bleed across the angular gaps.
        let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: isSegmented ? .butt : .round)

        ZStack {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                let from = segment.start + gap / 2
                let to = max(from, segment.end - gap / 2)

                Circle()
                    .trim(from: from, to: to)
                    .stroke(Color.white.opacity(0.2), style: style)

                if segment.fill > 0 {
                    Circle()
                        .trim(from: from, to: from + (to - from) * segment.fill)
                        .stroke(tint, style: style)
                }
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-90))
        .animation(animationSuppressed ? nil : .linear(duration: 0.5), value: progress)
        .accessibilityHidden(true)
    }
}
