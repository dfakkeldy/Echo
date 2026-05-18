import Foundation

struct MarkerInjector {
    func inject(
        markers: [SyncMarker],
        alignments: [AlignmentResult],
        segments: [EnhancedTranscriptionSegment]
    ) -> [EnhancedTranscriptionSegment] {
        guard !markers.isEmpty else {
            return segments.map { seg in
                EnhancedTranscriptionSegment(
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    markers: nil,
                    formatting: seg.formatting
                )
            }
        }

        var markerAssignments: [Int: [SyncMarker]] = [:]

        for marker in markers {
            var bestAlignmentIndex: Int?
            var bestDistance = Int.max

            for (idx, alignment) in alignments.enumerated() {
                if alignment.epubCharRange.contains(marker.epubCharOffset) {
                    bestAlignmentIndex = idx
                    break
                }
                let dist = Swift.min(
                    abs(marker.epubCharOffset - alignment.epubCharRange.lowerBound),
                    abs(marker.epubCharOffset - alignment.epubCharRange.upperBound)
                )
                if dist < bestDistance {
                    bestDistance = dist
                    bestAlignmentIndex = idx
                }
            }

            if let idx = bestAlignmentIndex, idx < segments.count {
                markerAssignments[idx, default: []].append(marker)
            }
        }

        return segments.enumerated().map { index, segment in
            EnhancedTranscriptionSegment(
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                markers: markerAssignments[index],
                formatting: segment.formatting
            )
        }
    }
}
