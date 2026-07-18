// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct BookProgressSegmentMetricsTests {

    // MARK: - Boundary sanitization

    @Test("boundaries are sorted, deduped, and clamped to the open interval")
    func sanitizeBoundaries() {
        let raw = [0.9, 0.25, 0.0, 1.0, -0.3, 1.4, 0.2500001, 0.5]
        let cleaned = BookProgressSegmentMetrics.sanitizedBoundaries(raw, minSeparation: 0.01)
        #expect(cleaned == [0.25, 0.5, 0.9])
    }

    @Test("boundaries too close to the edges are dropped")
    func sanitizeDropsEdgeHuggers() {
        let cleaned = BookProgressSegmentMetrics.sanitizedBoundaries(
            [0.001, 0.5, 0.999], minSeparation: 0.05)
        #expect(cleaned == [0.5])
    }

    // MARK: - Segment fills

    @Test("segments partition the bar and fill relative to progress")
    func segmentFills() {
        let segments = BookProgressSegmentMetrics.segments(
            boundaries: [0.25, 0.5], progress: 0.375)

        #expect(segments.count == 3)
        #expect(segments[0] == .init(start: 0, end: 0.25, fill: 1))
        #expect(abs(segments[1].fill - 0.5) < 0.0001)
        #expect(segments[2].fill == 0)
        // Spans always cover the full bar.
        #expect(abs(segments.reduce(0) { $0 + $1.span } - 1.0) < 0.0001)
    }

    @Test("progress outside 0...1 clamps instead of over/underfilling")
    func progressClamps() {
        let over = BookProgressSegmentMetrics.segments(boundaries: [0.5], progress: 1.7)
        let under = BookProgressSegmentMetrics.segments(boundaries: [0.5], progress: -0.4)
        #expect(over.allSatisfy { $0.fill == 1 })
        #expect(under.allSatisfy { $0.fill == 0 })
    }

    @Test("no boundaries yields a single full-span segment")
    func noBoundariesSingleSegment() {
        let segments = BookProgressSegmentMetrics.segments(boundaries: [], progress: 0.6)
        #expect(segments == [.init(start: 0, end: 1, fill: 0.6)])
    }

    // MARK: - Linear convenience

    @Test("linear segments merge chapters narrower than the minimum capsule")
    func linearMergesNarrowSegments() {
        // 100 pt wide bar, min segment 3 pt + 2 pt gap => 5% minimum separation.
        let segments = BookProgressSegmentMetrics.linearSegments(
            rawBoundaries: [0.5, 0.51, 0.52, 0.9], progress: 0, availableWidth: 100)
        #expect(segments.count == 3)
        #expect(segments.map(\.start) == [0, 0.5, 0.9])
    }

    @Test("zero available width degrades to one segment instead of dividing by zero")
    func zeroWidthSafe() {
        let segments = BookProgressSegmentMetrics.linearSegments(
            rawBoundaries: [0.5], progress: 0.2, availableWidth: 0)
        #expect(segments.count == 1)
    }

    // MARK: - Ring convenience

    @Test("ring falls back to a single segment beyond the readable chapter count")
    func ringFallsBackWhenOvercrowded() {
        let many = (1..<60).map { Double($0) / 60.0 }
        let segments = BookProgressSegmentMetrics.ringSegments(rawBoundaries: many, progress: 0.5)
        #expect(segments.count == 1)
    }

    @Test("ring keeps segmentation at a typical chapter count")
    func ringSegmentsTypicalBook() {
        let boundaries = (1..<12).map { Double($0) / 12.0 }
        let segments = BookProgressSegmentMetrics.ringSegments(
            rawBoundaries: boundaries, progress: 0.5)
        #expect(segments.count == 12)
    }
}
