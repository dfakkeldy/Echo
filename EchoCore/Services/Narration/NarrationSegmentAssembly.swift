// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum NarrationSegmentAssembly {
    struct AssembledChapter: Equatable, Sendable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        let spokenDuration: TimeInterval
        let durableDuration: TimeInterval
        let anchors: [AlignmentAnchorRecord]
        let spokenBlockIDs: [String]
    }

    enum Error: Swift.Error, Equatable {
        case empty
        case missingSegmentIndex
        case mismatchedChapter(expected: Int, actual: Int)
        case mismatchedDisplayNumber(expected: Int, actual: Int)
        case nonContiguousSegment(expected: Int, actual: Int)
    }

    static func assemble(
        _ renderedSegments: [NarrationService.RenderedNarrationFile],
        leadOutPadSeconds: TimeInterval = NarrationService.leadOutPadSeconds
    ) throws -> AssembledChapter {
        guard !renderedSegments.isEmpty else { throw Error.empty }

        let indexedSegments = try renderedSegments.map { segment in
            guard let segmentIndex = segment.segmentIndex else {
                throw Error.missingSegmentIndex
            }
            return (segmentIndex, segment)
        }.sorted { $0.0 < $1.0 }

        let first = indexedSegments[0].1
        var anchors: [AlignmentAnchorRecord] = []
        var spokenBlockIDs: [String] = []
        var cursor: TimeInterval = 0

        for (expectedIndex, item) in indexedSegments.enumerated() {
            let (segmentIndex, segment) = item
            guard segmentIndex == expectedIndex else {
                throw Error.nonContiguousSegment(expected: expectedIndex, actual: segmentIndex)
            }
            guard segment.chapterIndex == first.chapterIndex else {
                throw Error.mismatchedChapter(
                    expected: first.chapterIndex,
                    actual: segment.chapterIndex)
            }
            guard segment.chapterDisplayNumber == first.chapterDisplayNumber else {
                throw Error.mismatchedDisplayNumber(
                    expected: first.chapterDisplayNumber,
                    actual: segment.chapterDisplayNumber)
            }

            anchors.append(contentsOf: segment.anchors.map { anchor in
                var shifted = anchor
                shifted.audioTime += cursor
                if let audioEndTime = shifted.audioEndTime {
                    shifted.audioEndTime = audioEndTime + cursor
                }
                return shifted
            })
            spokenBlockIDs.append(contentsOf: segment.spokenBlockIDs)
            cursor += segment.duration
        }

        return AssembledChapter(
            chapterIndex: first.chapterIndex,
            chapterDisplayNumber: first.chapterDisplayNumber,
            spokenDuration: cursor,
            durableDuration: cursor > 0 ? cursor + leadOutPadSeconds : 0,
            anchors: anchors,
            spokenBlockIDs: spokenBlockIDs)
    }
}
