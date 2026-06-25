// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationSegmentAssemblyTests {
    @Test func assembleOffsetsAnchorsAndAddsOneDurableLeadOut() throws {
        let first = renderedSegment(
            segmentIndex: 0,
            duration: 1.2,
            blockIDs: ["b0", "b1"],
            anchors: [
                anchor(id: "a0", blockID: "b0", start: 0.0, end: 0.4),
                anchor(id: "a1", blockID: "b1", start: 0.4, end: 1.2),
            ])
        let second = renderedSegment(
            segmentIndex: 1,
            duration: 0.8,
            blockIDs: ["b2"],
            anchors: [
                anchor(id: "a2", blockID: "b2", start: 0.0, end: 0.8),
            ])

        let assembled = try NarrationSegmentAssembly.assemble([second, first])

        #expect(assembled.chapterIndex == 3)
        #expect(assembled.chapterDisplayNumber == 4)
        #expect(abs(assembled.spokenDuration - 2.0) < 0.0001)
        #expect(abs(assembled.durableDuration - (2.0 + NarrationService.leadOutPadSeconds)) < 0.0001)
        #expect(assembled.spokenBlockIDs == ["b0", "b1", "b2"])
        #expect(assembled.anchors.map(\.epubBlockID) == ["b0", "b1", "b2"])
        #expect(abs(assembled.anchors[0].audioTime - 0.0) < 0.0001)
        #expect(abs((assembled.anchors[0].audioEndTime ?? -1) - 0.4) < 0.0001)
        #expect(abs(assembled.anchors[1].audioTime - 0.4) < 0.0001)
        #expect(abs((assembled.anchors[1].audioEndTime ?? -1) - 1.2) < 0.0001)
        #expect(abs(assembled.anchors[2].audioTime - 1.2) < 0.0001)
        #expect(abs((assembled.anchors[2].audioEndTime ?? -1) - 2.0) < 0.0001)
    }

    @Test func assembleRejectsMissingSegmentIndexes() throws {
        let chapterFile = NarrationService.RenderedNarrationFile(
            chapterIndex: 3,
            chapterDisplayNumber: 4,
            segmentIndex: nil,
            fileURL: URL(fileURLWithPath: "/tmp/chapter.m4a"),
            duration: 1,
            anchors: [],
            spokenBlockIDs: [])

        #expect(throws: NarrationSegmentAssembly.Error.missingSegmentIndex) {
            try NarrationSegmentAssembly.assemble([chapterFile])
        }
    }

    @Test func assembleRejectsNonContiguousSegments() throws {
        let first = renderedSegment(segmentIndex: 0, duration: 1, blockIDs: ["b0"])
        let third = renderedSegment(segmentIndex: 2, duration: 1, blockIDs: ["b2"])

        #expect(throws: NarrationSegmentAssembly.Error.nonContiguousSegment(expected: 1, actual: 2)) {
            try NarrationSegmentAssembly.assemble([first, third])
        }
    }

    private func renderedSegment(
        segmentIndex: Int,
        duration: TimeInterval,
        blockIDs: [String],
        anchors: [AlignmentAnchorRecord] = []
    ) -> NarrationService.RenderedNarrationFile {
        NarrationService.RenderedNarrationFile(
            chapterIndex: 3,
            chapterDisplayNumber: 4,
            segmentIndex: segmentIndex,
            fileURL: URL(fileURLWithPath: "/tmp/segment-\(segmentIndex).m4a"),
            duration: duration,
            anchors: anchors,
            spokenBlockIDs: blockIDs)
    }

    private func anchor(
        id: String,
        blockID: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id,
            audiobookID: "book",
            epubBlockID: blockID,
            audioTime: start,
            audioEndTime: end,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.synthesized.rawValue,
            note: nil,
            createdAt: nil,
            modifiedAt: nil)
    }
}
