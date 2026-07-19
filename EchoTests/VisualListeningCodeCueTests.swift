// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct VisualListeningCodeCueTests {

    private func codeBlock(
        id: String, sequence: Int, code: String, cue: String?, chapter: Int = 0
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "a1", spineHref: "s.xhtml", spineIndex: 0,
            blockIndex: sequence, sequenceIndex: sequence,
            blockKind: EPubBlockRecord.Kind.code.rawValue,
            text: code, htmlContent: nil, cardColor: nil, imagePath: nil,
            chapterIndex: chapter, isHidden: false, hiddenReason: nil,
            wordCount: 1, markers: nil, textFormats: nil,
            narrationText: cue, codeLanguage: "python", createdAt: nil, modifiedAt: nil)
    }

    private func textBlock(id: String, sequence: Int, text: String, chapter: Int = 0)
        -> EPubBlockRecord
    {
        EPubBlockRecord(
            id: id, audiobookID: "a1", spineHref: "s.xhtml", spineIndex: 0,
            blockIndex: sequence, sequenceIndex: sequence,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text, htmlContent: nil, cardColor: nil, imagePath: nil,
            chapterIndex: chapter, isHidden: false, hiddenReason: nil,
            wordCount: 3, markers: nil, textFormats: nil,
            narrationText: nil, codeLanguage: nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func codeBlockWithTimelineRowBecomesVisualCue() {
        let blocks = [
            textBlock(id: "t1", sequence: 0, text: "Consider this function."),
            codeBlock(id: "c1", sequence: 1, code: "def f():\n    return 1", cue: "Listing 1."),
        ]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 5, blockID: "t1", chapterIndex: 0, segmentKey: nil),
            (start: 5, end: 7, blockID: "c1", chapterIndex: 0, segmentKey: nil),
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 5.5,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        guard case .code(let text, let language) = snapshot.visualCue?.content else {
            Issue.record(
                "expected a code visual cue, got \(String(describing: snapshot.visualCue))")
            return
        }
        #expect(text == "def f():\n    return 1")
        #expect(language == "python")
        #expect(snapshot.visualCue?.caption == "Listing 1.")
    }

    @Test func codeSubtitleIsTheCueNeverTheRawCode() {
        let blocks = [
            codeBlock(id: "c1", sequence: 0, code: "let x = 5", cue: "Listing 2.")
        ]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 2, blockID: "c1", chapterIndex: 0, segmentKey: nil)
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 1,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        #expect(snapshot.subtitleCue?.text == "Listing 2.")
    }

    @Test func codeBlockWithoutTimelineRowDerivesWindowFromNeighborProse() {
        let blocks = [
            textBlock(id: "t1", sequence: 0, text: "The next listing shows the loop."),
            codeBlock(id: "c1", sequence: 1, code: "for x in items:\n    use(x)", cue: nil),
        ]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 10, blockID: "t1", chapterIndex: 0, segmentKey: nil)
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 2,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        guard case .code = snapshot.visualCue?.content else {
            Issue.record("expected derived-window code cue")
            return
        }
        #expect(snapshot.visualCue?.source == .derivedFromNearbyText)
    }

    @Test func imageCuesStillWork() {
        var image = textBlock(id: "i1", sequence: 0, text: "A caption")
        image.blockKind = EPubBlockRecord.Kind.image.rawValue
        image.imagePath = "figs/one.png"
        let blocks = [image, textBlock(id: "t1", sequence: 1, text: "Prose after.")]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (start: 0, end: 10, blockID: "t1", chapterIndex: 0, segmentKey: nil)
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks, timeline: timeline, words: [], time: 2,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .begin)
        #expect(snapshot.visualCue?.imagePath == "figs/one.png")
        guard case .image(let path) = snapshot.visualCue?.content else {
            Issue.record("expected image content")
            return
        }
        #expect(path == "figs/one.png")
    }
}
