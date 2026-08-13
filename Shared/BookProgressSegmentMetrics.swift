// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure layout math for chapter-segmented book-progress indicators.
///
/// The iPhone ships interior chapter/track boundaries as fractions of the
/// whole-book duration (`bookBoundaryFractions` in the watch context). This
/// enum turns those raw boundaries plus a progress fraction into per-segment
/// spans and fills that the watch's linear bar and progress ring can render,
/// independent of pixel geometry so the math stays unit-testable.
nonisolated enum BookProgressSegmentMetrics {
    /// One segment of the whole-book indicator, in the 0...1 progress domain.
    struct Segment: Equatable {
        /// Fractional span of the whole bar this segment occupies.
        let start: Double
        let end: Double
        /// How full this segment is, 0...1 within its own span.
        let fill: Double

        var span: Double { end - start }
    }

    /// Gap between capsules in the linear bar, in points.
    static let linearGapWidth: CGFloat = 2
    /// Narrowest capsule worth drawing; below this, boundaries merge.
    static let minLinearSegmentWidth: CGFloat = 3
    /// Angular gap between ring arcs, as a fraction of the circumference.
    static let ringGapFraction: Double = 0.014
    /// Beyond this many segments the ring reads as a dashed circle, not
    /// chapters — callers should fall back to the unsegmented ring.
    static let maxRingSegments = 24
    /// Cap on boundaries shipped over WatchConnectivity per state message;
    /// anything beyond the render limits above is dead payload.
    static let maxTransportBoundaries = 40

    /// Reduces a chronologically ordered boundary list to the transport cap by
    /// even down-sampling, so the retained boundaries still span the whole
    /// book instead of biasing to its first chapters.
    static func transportBoundaries(_ raw: [Double]) -> [Double] {
        guard raw.count > maxTransportBoundaries else { return raw }
        let step = Double(raw.count) / Double(maxTransportBoundaries)
        return (0..<maxTransportBoundaries).map { raw[Int(Double($0) * step)] }
    }

    /// Filters raw boundary fractions to a strictly increasing sequence inside
    /// (0, 1), merging boundaries closer together than `minSeparation` so no
    /// rendered segment collapses below its minimum visual width.
    static func sanitizedBoundaries(_ raw: [Double], minSeparation: Double) -> [Double] {
        var kept: [Double] = []
        for boundary in raw.sorted() {
            guard boundary > 0, boundary < 1 else { continue }
            guard boundary - (kept.last ?? 0) >= minSeparation else { continue }
            guard 1 - boundary >= minSeparation else { continue }
            kept.append(boundary)
        }
        return kept
    }

    /// Splits the 0...1 domain at `boundaries` (assumed sanitized) and computes
    /// each segment's fill for the given overall progress fraction.
    static func segments(boundaries: [Double], progress: Double) -> [Segment] {
        let clampedProgress = min(1, max(0, progress))
        let edges = [0.0] + boundaries + [1.0]
        return zip(edges, edges.dropFirst()).map { start, end in
            let span = end - start
            let fill = span > 0 ? min(1, max(0, (clampedProgress - start) / span)) : 0
            return Segment(start: start, end: end, fill: fill)
        }
    }

    /// Convenience for the linear bar: sanitizes against the available pixel
    /// width so every capsule stays at least `minLinearSegmentWidth` wide.
    static func linearSegments(
        rawBoundaries: [Double], progress: Double, availableWidth: CGFloat
    ) -> [Segment] {
        guard availableWidth > 0 else { return segments(boundaries: [], progress: progress) }
        let minSeparation = Double((minLinearSegmentWidth + linearGapWidth) / availableWidth)
        let boundaries = sanitizedBoundaries(rawBoundaries, minSeparation: minSeparation)
        return segments(boundaries: boundaries, progress: progress)
    }

    /// Convenience for the ring: merges segments narrower than one gap and
    /// falls back to a single full-circle segment when the chapter count is
    /// too high to read as segmentation.
    static func ringSegments(rawBoundaries: [Double], progress: Double) -> [Segment] {
        let boundaries = sanitizedBoundaries(rawBoundaries, minSeparation: ringGapFraction * 2)
        guard boundaries.count + 1 <= maxRingSegments else {
            return segments(boundaries: [], progress: progress)
        }
        return segments(boundaries: boundaries, progress: progress)
    }
}
