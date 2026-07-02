// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationSegmentReadinessTests {
    private let audiobookID = "book_id"
    private let voice = VoiceID("af_heart")

    @Test func assembledChapterValidatesFilesAndRenderedMetadata() throws {
        let planned = [
            segment(0, blocks: [block("b0", text: "First")]),
            segment(1, blocks: [block("b1", text: "Second")]),
        ]
        let rendered = [
            renderedSegment(0, duration: 1.0, blockIDs: ["b0"]),
            renderedSegment(1, duration: 2.0, blockIDs: ["b1"]),
        ]
        let files = rendered.map(\.fileURL)

        let assembled = try NarrationSegmentReadiness.assembledChapter(
            for: planned,
            renderedSegments: rendered,
            files: files,
            audiobookID: audiobookID,
            voice: voice,
            leadOutPadSeconds: 0.5)

        #expect(assembled?.chapterIndex == 0)
        #expect(assembled?.chapterDisplayNumber == 1)
        #expect(assembled?.spokenDuration == 3.0)
        #expect(assembled?.durableDuration == 3.5)
        #expect(assembled?.anchors.map(\.epubBlockID) == ["b0", "b1"])
        #expect(assembled?.anchors.map(\.audioTime) == [0.0, 1.0])
        #expect(assembled?.anchors.map(\.audioEndTime) == [1.0, 3.0])
        #expect(assembled?.spokenBlockIDs == ["b0", "b1"])
    }

    @Test func assembledChapterWaitsForCanonicalSegmentFilesAndRenderedOutputs() throws {
        let planned = [
            segment(0, blocks: [block("b0", text: "First")]),
            segment(1, blocks: [block("b1", text: "Second")]),
        ]
        let wrongVoice = fileURL(chapter: 0, segment: 1, voice: VoiceID("bf_emma"))
        let files = [fileURL(chapter: 0, segment: 0, voice: voice), wrongVoice]
        let rendered = [
            renderedSegment(0, duration: 1.0, blockIDs: ["b0"]),
            renderedSegment(1, duration: 2.0, blockIDs: ["b1"], fileURL: wrongVoice),
        ]

        let assembled = try NarrationSegmentReadiness.assembledChapter(
            for: planned,
            renderedSegments: rendered,
            files: files,
            audiobookID: audiobookID,
            voice: voice)

        #expect(assembled == nil)
    }

    @Test func assembledChapterRequiresMatchingSignedSegmentFilesWhenProvided() throws {
        let expectedSignature = "aaaaaaaaaaaaaaaa"
        let staleSignature = "bbbbbbbbbbbbbbbb"
        let planned = [
            segment(0, blocks: [block("b0", text: "First")])
        ]
        let staleURL = fileURL(
            chapter: 0,
            segment: 0,
            voice: voice,
            contentSignature: staleSignature)
        let rendered = [
            renderedSegment(0, duration: 1.0, blockIDs: ["b0"], fileURL: staleURL)
        ]

        let assembled = try NarrationSegmentReadiness.assembledChapter(
            for: planned,
            renderedSegments: rendered,
            files: [staleURL],
            audiobookID: audiobookID,
            voice: voice,
            contentSignaturesBySegmentIndex: [0: expectedSignature])

        #expect(assembled == nil)
    }

    @Test func assembledChapterRejectsNonContiguousPlans() throws {
        let planned = [
            segment(0, blocks: [block("b0", text: "First")]),
            segment(2, blocks: [block("b2", text: "Third")]),
        ]

        #expect(throws: NarrationSegmentReadiness.Error.nonContiguousPlan(expected: 1, actual: 2)) {
            _ = try NarrationSegmentReadiness.assembledChapter(
                for: planned,
                renderedSegments: [],
                files: [],
                audiobookID: audiobookID,
                voice: voice)
        }
    }

    @Test func assembledChapterRejectsMismatchedSpokenBlocks() throws {
        let planned = [
            segment(
                0,
                blocks: [
                    block("b0", text: "First"),
                    block("image", text: nil),
                ])
        ]
        let rendered = [
            renderedSegment(0, duration: 1.0, blockIDs: ["image"])
        ]

        #expect(
            throws: NarrationSegmentReadiness.Error.mismatchedSpokenBlocks(
                segmentIndex: 0,
                expected: ["b0"],
                actual: ["image"])
        ) {
            _ = try NarrationSegmentReadiness.assembledChapter(
                for: planned,
                renderedSegments: rendered,
                files: rendered.map(\.fileURL),
                audiobookID: audiobookID,
                voice: voice)
        }
    }

    private func segment(
        _ segmentIndex: Int,
        blocks: [EPubBlockRecord]
    ) -> NarrationSegmentPlanner.PlannedSegment {
        NarrationSegmentPlanner.PlannedSegment(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: segmentIndex,
            blocks: blocks)
    }

    private func block(_ id: String, text: String?) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: audiobookID,
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: "paragraph",
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil)
    }

    private func renderedSegment(
        _ segmentIndex: Int,
        duration: TimeInterval,
        blockIDs: [String],
        fileURL: URL? = nil
    ) -> NarrationService.RenderedNarrationFile {
        let firstBlock = blockIDs.first ?? "block"
        return NarrationService.RenderedNarrationFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: segmentIndex,
            fileURL: fileURL ?? self.fileURL(chapter: 0, segment: segmentIndex, voice: voice),
            duration: duration,
            anchors: [
                AlignmentAnchorRecord(
                    id: "a\(segmentIndex)",
                    audiobookID: audiobookID,
                    epubBlockID: firstBlock,
                    audioTime: 0,
                    audioEndTime: duration,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.synthesized.rawValue,
                    note: nil,
                    createdAt: "2026-01-01T00:00:00Z",
                    modifiedAt: "2026-01-01T00:00:00Z")
            ],
            spokenBlockIDs: blockIDs,
            synthesisWordTimingsByBlock: [:])
    }

    private func fileURL(
        chapter: Int,
        segment: Int,
        voice: VoiceID,
        contentSignature: String? = nil
    ) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(
            NarrationFileNaming.segmentFileName(
                audiobookID: audiobookID,
                chapterIndex: chapter,
                segmentIndex: segment,
                voice: voice,
                contentSignature: contentSignature))
    }
}
