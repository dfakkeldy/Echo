import Foundation

struct MarkerInjector {
    /// Minimum character distance a marker must be from the nearest alignment
    /// range boundary before it is considered "orphaned" — i.e. EPUB content
    /// with no corresponding audio. Orphaned markers become un-timestamped
    /// segments in the output.
    private let orphanThreshold: Int = 50

    func inject(
        markers: [SyncMarker],
        alignments: [AlignmentResult],
        segments: [EnhancedTranscriptionSegment]
    ) -> [EnhancedTranscriptionSegment] {
        guard !markers.isEmpty else {
            return segments.enumerated().map { index, seg in
                EnhancedTranscriptionSegment(
                    sequenceIndex: index,
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    markers: nil,
                    formatting: seg.formatting
                )
            }
        }

        // ---- 1. Classify each marker as attached or orphaned ----

        var attachedMarkers: [Int: [SyncMarker]] = [:]   // segment index
        var orphanedMarkers: [(marker: SyncMarker, epubOffset: Int)] = []

        for marker in markers {
            var bestIdx: Int?
            var bestDistance = Int.max

            for (idx, alignment) in alignments.enumerated() {
                if alignment.epubCharRange.contains(marker.epubCharOffset) {
                    bestIdx = idx
                    bestDistance = 0
                    break
                }
                let dist = Swift.min(
                    abs(marker.epubCharOffset - alignment.epubCharRange.lowerBound),
                    abs(marker.epubCharOffset - alignment.epubCharRange.upperBound)
                )
                if dist < bestDistance {
                    bestDistance = dist
                    bestIdx = idx
                }
            }

            if let idx = bestIdx, bestDistance <= orphanThreshold, idx < segments.count {
                attachedMarkers[idx, default: []].append(marker)
            } else {
                orphanedMarkers.append((marker, marker.epubCharOffset))
            }
        }

        // ---- 2. Build timestamped segments ----

        var output: [EnhancedTranscriptionSegment] = []

        for (index, segment) in segments.enumerated() {
            output.append(EnhancedTranscriptionSegment(
                sequenceIndex: 0, // placeholder — caller assigns final indices
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                markers: attachedMarkers[index],
                formatting: segment.formatting
            ))
        }

        // ---- 3. Build un-timestamped segments for orphaned markers ----

        for (marker, _) in orphanedMarkers {
            let displayText: String
            switch marker.type {
            case .image:
                displayText = marker.payload.isEmpty ? "Image" : marker.payload
            case .footnote:
                displayText = marker.payload.isEmpty ? "Footnote" : marker.payload
            case .chapterStart:
                displayText = "Chapter: \(marker.payload)"
            default:
                displayText = marker.payload.isEmpty ? marker.type.rawValue : marker.payload
            }

            output.append(EnhancedTranscriptionSegment(
                sequenceIndex: 0, // placeholder
                text: displayText,
                startTime: nil,
                endTime: nil,
                markers: [marker],
                formatting: nil
            ))
        }

        // ---- 4. Merge: interleave untimestamped orphan markers by epubCharOffset ----

        let sortedTimestamped = output.filter { $0.isTimestamped }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }

        // Sort orphaned markers by epubCharOffset so they are inserted in EPUB order.
        let sortedOrphans = output.filter { !$0.isTimestamped }
            .sorted { a, b in
                let offsetA = a.markers?.first?.epubCharOffset ?? Int.max
                let offsetB = b.markers?.first?.epubCharOffset ?? Int.max
                return offsetA < offsetB
            }

        // Walk through alignments in order, appending each timestamped segment
        // followed by any orphaned markers whose epubCharOffset belongs before
        // the next alignment's lowerBound.
        var result: [EnhancedTranscriptionSegment] = []
        var orphanIdx = 0

        for (ai, _) in alignments.enumerated() {
            let nextLowerBound: Int
            if ai + 1 < alignments.count {
                nextLowerBound = alignments[ai + 1].epubCharRange.lowerBound
            } else {
                nextLowerBound = Int.max
            }

            // Append the timestamped segment for this alignment.
            if ai < sortedTimestamped.count {
                result.append(sortedTimestamped[ai])
            }

            // Append any orphans whose epubCharOffset falls before the next alignment.
            while orphanIdx < sortedOrphans.count,
                  let offset = sortedOrphans[orphanIdx].markers?.first?.epubCharOffset,
                  offset < nextLowerBound {
                result.append(sortedOrphans[orphanIdx])
                orphanIdx += 1
            }
        }

        // Append any remaining orphans whose offsets are beyond all alignments.
        while orphanIdx < sortedOrphans.count {
            result.append(sortedOrphans[orphanIdx])
            orphanIdx += 1
        }

        return result
    }
}
