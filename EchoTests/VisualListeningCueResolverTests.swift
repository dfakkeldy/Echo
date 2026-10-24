// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct VisualListeningCueResolverTests {
    @Test func derivedImageCuesFilterVisibleImagesAndPreserveSequence() {
        let blocks = [
            block("intro", sequence: 0, kind: .paragraph, text: "Before the figure"),
            block("hidden-image", sequence: 1, kind: .image, imagePath: "hidden.jpg", hidden: true),
            block("missing-image", sequence: 2, kind: .image, imagePath: nil),
            block("figure", sequence: 3, kind: .image, imagePath: "figures/one.jpg"),
            block(
                "captioned-text", sequence: 4, kind: .paragraph, text: "Look at the bright edge."),
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: [timeline(10, 20, blockID: "captioned-text")],
            words: [],
            time: 12,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin
        )

        #expect(snapshot.visualCue?.blockID == "figure")
        #expect(snapshot.visualCue?.imagePath == "figures/one.jpg")
        #expect(snapshot.visualCue?.sequenceIndex == 3)
        #expect(snapshot.visualCue?.source == .derivedFromNearbyText)
    }

    @Test func timestampedImageUsesItsOwnRuntime() {
        let blocks = [
            block("figure", sequence: 0, kind: .image, imagePath: "figures/timed.jpg"),
            block("text", sequence: 1, kind: .paragraph, text: "This text has its own timing."),
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: [
                timeline(5, 10, blockID: "text"),
                timeline(30, 40, blockID: "figure"),
            ],
            words: [],
            time: 35,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .midpoint
        )

        #expect(snapshot.visualCue?.blockID == "figure")
        #expect(snapshot.visualCue?.displayStartTime == 30)
        #expect(snapshot.visualCue?.displayEndTime == 40)
        #expect(snapshot.visualCue?.source == .explicitTimeline)
        #expect(snapshot.visualCue?.subtitleBlockID == "text")
        #expect(snapshot.subtitleCue?.blockID == "text")
        #expect(snapshot.subtitleCue?.text == "This text has its own timing.")
    }

    @Test func trackScopePreventsSameTimeImageCollisions() {
        let blocks = [
            block("c0-image", sequence: 0, kind: .image, imagePath: "c0.jpg", chapter: 0),
            block("c1-image", sequence: 1, kind: .image, imagePath: "c1.jpg", chapter: 1),
        ]
        let cache = [
            timeline(0, 10, blockID: "c0-image", chapter: 0),
            timeline(0, 10, blockID: "c1-image", chapter: 1),
        ]

        let chapterZero = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: cache,
            words: [],
            time: 5,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: [0],
            syncPoint: .begin
        )
        let chapterOne = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: cache,
            words: [],
            time: 5,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: [1],
            syncPoint: .begin
        )

        #expect(chapterZero.visualCue?.blockID == "c0-image")
        #expect(chapterOne.visualCue?.blockID == "c1-image")
    }

    @Test func beginAndMidpointDerivedTimingUseDifferentWindows() {
        let blocks = [
            block("figure", sequence: 0, kind: .image, imagePath: "figure.jpg"),
            block("text", sequence: 1, kind: .paragraph, text: "The relevant section."),
        ]
        let rows = [timeline(10, 20, blockID: "text")]

        let begin = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: rows,
            words: [],
            time: 10,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin
        )
        let midpoint = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: rows,
            words: [],
            time: 6,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .midpoint
        )

        #expect(begin.visualCue?.displayStartTime == 10)
        #expect(begin.visualCue?.displayEndTime == 20)
        #expect(midpoint.visualCue?.displayStartTime == 5)
        #expect(midpoint.visualCue?.displayEndTime == 25)
    }

    @Test func midpointDerivedImageKeepsSubtitleBeforeReferenceTextStarts() {
        let blocks = [
            block("figure", sequence: 0, kind: .image, imagePath: "figure.jpg"),
            block("text", sequence: 1, kind: .paragraph, text: "The captioned section."),
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: [timeline(10, 20, blockID: "text")],
            words: [],
            time: 6,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .midpoint
        )

        #expect(snapshot.visualCue?.blockID == "figure")
        #expect(snapshot.visualCue?.subtitleBlockID == "text")
        #expect(snapshot.subtitleCue?.blockID == "text")
        #expect(snapshot.subtitleCue?.text == "The captioned section.")
    }

    @Test func subtitleUsesActiveBlockAndWordProgress() {
        let blocks = [
            block("text", sequence: 0, kind: .paragraph, text: "One two three.")
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: [timeline(0, 10, blockID: "text")],
            words: [
                (start: 0, end: 1, blockID: "text", wordIndex: 0),
                (start: 1, end: 2, blockID: "text", wordIndex: 1),
                (start: 2, end: 3, blockID: "text", wordIndex: 2),
            ],
            time: 1.5,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin
        )

        #expect(snapshot.activeBlockID == "text")
        #expect(snapshot.subtitleCue?.text == "One two three.")
        #expect(snapshot.subtitleCue?.activeWordIndex == 1)
        #expect(snapshot.subtitleCue?.alreadyHeardWordCount == 1)
    }

    @Test func subtitleWordProgressUsesDisplayOrdinalForSparseTimingIndices() {
        let blocks = [
            block("text", sequence: 0, kind: .paragraph, text: "One two three.")
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: [timeline(0, 10, blockID: "text")],
            words: [
                (start: 0, end: 1, blockID: "text", wordIndex: 0),
                (start: 1, end: 2, blockID: "text", wordIndex: 10_000),
                (start: 2, end: 3, blockID: "text", wordIndex: 20_000),
            ],
            time: 1.5,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin
        )

        #expect(snapshot.subtitleCue?.activeWordIndex == 1)
        #expect(snapshot.subtitleCue?.alreadyHeardWordCount == 1)
    }

    @Test func subtitleFallsBackToBlockTextWithoutWordTiming() {
        let blocks = [
            block("text", sequence: 0, kind: .paragraph, text: "No precise word timing.")
        ]
        let snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: [timeline(0, 10, blockID: "text")],
            words: [],
            time: 4,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin
        )

        #expect(snapshot.subtitleCue?.blockID == "text")
        #expect(snapshot.subtitleCue?.activeWordIndex == nil)
        #expect(snapshot.subtitleCue?.alreadyHeardWordCount == 0)
    }

    @Test func preparedSnapshotMatchesLegacySnapshot() {
        let blocks = [
            block("text1", sequence: 0, kind: .paragraph, text: "One two three."),
            block("figure1", sequence: 1, kind: .image, imagePath: "figures/one.jpg"),
            block("text2", sequence: 2, kind: .paragraph, text: "Four five six."),
            block("code1", sequence: 3, kind: .code, text: "let x = 1"),
        ]
        let timeline = [
            timeline(0, 5, blockID: "text1"),
            timeline(5, 8, blockID: "figure1"),
            timeline(8, 14, blockID: "text2"),
            timeline(14, 20, blockID: "code1"),
        ]
        let words: [ReaderActiveBlockResolver.WordRow] = [
            (start: 0, end: 1, blockID: "text1", wordIndex: 0),
            (start: 1, end: 2, blockID: "text1", wordIndex: 1),
            (start: 2, end: 3, blockID: "text1", wordIndex: 2),
            (start: 8, end: 9, blockID: "text2", wordIndex: 0),
            (start: 9, end: 10, blockID: "text2", wordIndex: 1),
            (start: 10, end: 11, blockID: "text2", wordIndex: 2),
        ]

        let orderedBlocks = blocks.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        let blocksByID = Dictionary(uniqueKeysWithValues: orderedBlocks.map { ($0.id, $0) })

        let prepared = VisualListeningCueResolver.visualCues(
            blocks: orderedBlocks, blocksByID: blocksByID, timeline: timeline,
            currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
            syncPoint: .midpoint)

        for t in stride(from: 0.0, through: 20.0, by: 0.5) {
            let legacy = VisualListeningCueResolver.snapshot(
                blocks: blocks, timeline: timeline, words: words, time: t,
                currentTrackSegmentKey: nil, currentTrackChapterIndices: nil,
                syncPoint: .midpoint)
            let fast = VisualListeningCueResolver.snapshot(
                preparedCues: prepared, blocksByID: blocksByID, words: words,
                timeline: timeline, time: t,
                currentTrackSegmentKey: nil, currentTrackChapterIndices: nil)
            #expect(
                fast == legacy,
                "mismatch at t=\(t): fast=\(String(describing: fast)) legacy=\(String(describing: legacy))"
            )
        }
    }

    // MARK: - Figure pacing

    @Test func captionedFigureStaysUpUntilTheNextFigure() {
        let blocks = [
            block("fig-a", sequence: 0, kind: .image, text: "The plan.", imagePath: "a.jpg"),
            block("p1", sequence: 1, kind: .paragraph, text: "A long discussion of the plan."),
            block("fig-b", sequence: 2, kind: .image, imagePath: "b.jpg"),
            block("p2", sequence: 3, kind: .paragraph, text: "What came next."),
        ]
        let rows = [
            timeline(0, 2, blockID: "fig-a"),
            timeline(2, 30, blockID: "p1"),
            timeline(30, 40, blockID: "p2"),
        ]

        let duringDiscussion = snapshot(blocks, rows, time: 20)
        #expect(duringDiscussion.visualCue?.blockID == "fig-a")
        #expect(duringDiscussion.visualCue?.source == .explicitTimeline)
        #expect(duringDiscussion.visualCue?.displayStartTime == 0)
        #expect(duringDiscussion.visualCue?.displayEndTime == 30)
        #expect(snapshot(blocks, rows, time: 31).visualCue?.blockID == "fig-b")
    }

    @Test func heldFigureDoesNotBringBackItsCaptionDuringSilence() {
        let blocks = [
            block("fig", sequence: 0, kind: .image, text: "The plan.", imagePath: "a.jpg"),
            block("p1", sequence: 1, kind: .paragraph, text: "First point."),
            block("p2", sequence: 2, kind: .paragraph, text: "Second point."),
        ]
        let rows = [
            timeline(0, 2, blockID: "fig"),
            timeline(2, 10, blockID: "p1"),
            timeline(11, 20, blockID: "p2"),
        ]

        #expect(snapshot(blocks, rows, time: 1).subtitleCue?.text == "The plan.")
        let silence = snapshot(blocks, rows, time: 10.5)
        #expect(silence.visualCue?.blockID == "fig")
        #expect(silence.visualCue?.holdStartTime == 2)
        #expect(silence.subtitleCue == nil)
        #expect(snapshot(blocks, rows, time: 12).subtitleCue?.text == "Second point.")
    }

    @Test func lastFigureInChapterHoldsUntilChapterEndButNotIntoNextChapter() {
        let blocks = [
            block("p0", sequence: 0, kind: .paragraph, text: "Intro."),
            block("fig", sequence: 1, kind: .image, imagePath: "fig.jpg"),
            block("p1", sequence: 2, kind: .paragraph, text: "About the figure."),
            block("p2", sequence: 3, kind: .paragraph, text: "Still talking."),
            block("c1", sequence: 4, kind: .paragraph, text: "Next chapter.", chapter: 1),
        ]
        let rows = [
            timeline(0, 5, blockID: "p0"),
            timeline(5, 10, blockID: "p1"),
            timeline(10, 25, blockID: "p2"),
            timeline(25, 40, blockID: "c1", chapter: 1),
        ]

        #expect(snapshot(blocks, rows, time: 4).visualCue == nil)
        #expect(snapshot(blocks, rows, time: 20).visualCue?.blockID == "fig")
        #expect(snapshot(blocks, rows, time: 20).visualCue?.displayEndTime == 25)
        #expect(snapshot(blocks, rows, time: 30).visualCue == nil)
    }

    @Test func consecutiveFiguresSplitTheirSharedWindowInReadingOrder() {
        let blocks = [
            block("fig-1", sequence: 0, kind: .image, imagePath: "1.jpg"),
            block("fig-2", sequence: 1, kind: .image, imagePath: "2.jpg"),
            block("fig-3", sequence: 2, kind: .image, imagePath: "3.jpg"),
            block("p", sequence: 3, kind: .paragraph, text: "One paragraph for three figures."),
        ]
        let rows = [timeline(0, 30, blockID: "p")]

        #expect(snapshot(blocks, rows, time: 5).visualCue?.blockID == "fig-1")
        #expect(snapshot(blocks, rows, time: 15).visualCue?.blockID == "fig-2")
        #expect(snapshot(blocks, rows, time: 25).visualCue?.blockID == "fig-3")
        #expect(snapshot(blocks, rows, time: 15).visualCue?.displayStartTime == 10)
        #expect(snapshot(blocks, rows, time: 25).visualCue?.displayStartTime == 20)
    }

    @Test func shortSharedWindowStillGivesEachFigureMinimumDwell() {
        let blocks = [
            block("fig-1", sequence: 0, kind: .image, imagePath: "1.jpg"),
            block("fig-2", sequence: 1, kind: .image, imagePath: "2.jpg"),
            block("p1", sequence: 2, kind: .paragraph, text: "Short."),
            block("p2", sequence: 3, kind: .paragraph, text: "A longer paragraph after."),
        ]
        let rows = [
            timeline(0, 2, blockID: "p1"),
            timeline(2, 20, blockID: "p2"),
        ]
        let dwell = VisualListeningCueResolver.minimumFigureDwell

        #expect(snapshot(blocks, rows, time: dwell - 0.5).visualCue?.blockID == "fig-1")
        let second = snapshot(blocks, rows, time: dwell + 0.5).visualCue
        #expect(second?.blockID == "fig-2")
        #expect(second?.displayStartTime == dwell)
        #expect(second?.displayEndTime == 20)
    }

    @Test func minimumDwellSharesTheRoomWhenTheNextFigureIsClose() {
        let blocks = [
            block("fig-1", sequence: 0, kind: .image, imagePath: "1.jpg"),
            block("p1", sequence: 1, kind: .paragraph, text: "Quick."),
            block("fig-2", sequence: 2, kind: .image, imagePath: "2.jpg"),
            block("p2", sequence: 3, kind: .paragraph, text: "Also quick."),
            block("fig-3", sequence: 4, kind: .image, text: "Spoken caption.", imagePath: "3.jpg"),
            block("p3", sequence: 5, kind: .paragraph, text: "The rest."),
        ]
        let rows = [
            timeline(0, 1, blockID: "p1"),
            timeline(1, 2, blockID: "p2"),
            timeline(2, 4, blockID: "fig-3"),
            timeline(4, 20, blockID: "p3"),
        ]
        let cues = VisualListeningCueResolver.visualCues(
            blocks: blocks,
            blocksByID: Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) }),
            timeline: rows,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin
        )
        let windows = Dictionary(
            uniqueKeysWithValues: cues.map {
                ($0.blockID, [$0.displayStartTime, $0.displayEndTime])
            })

        // fig-3's spoken caption starts at 2, so fig-1 and fig-2 share 0-2
        // rather than delaying fig-2 behind it.
        #expect(windows["fig-1"] == [0, 1])
        #expect(windows["fig-2"] == [1, 2])
        // Explicit caption cues keep their spoken start and hold to chapter end.
        #expect(windows["fig-3"] == [2, 20])
        #expect(snapshot(blocks, rows, time: 0.5).visualCue?.blockID == "fig-1")
        #expect(snapshot(blocks, rows, time: 1.5).visualCue?.blockID == "fig-2")
        #expect(snapshot(blocks, rows, time: 10).visualCue?.blockID == "fig-3")
    }

    private func snapshot(
        _ blocks: [EPubBlockRecord],
        _ rows: [ReaderActiveBlockResolver.TimelineRow],
        time: TimeInterval,
        syncPoint: VisualListeningSyncPoint = .begin
    ) -> VisualListeningSnapshot {
        VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: rows,
            words: [],
            time: time,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: syncPoint
        )
    }

    private func block(
        _ id: String,
        sequence: Int,
        kind: EPubBlockRecord.Kind,
        text: String? = nil,
        imagePath: String? = nil,
        chapter: Int? = 0,
        hidden: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: chapter ?? 0,
            blockIndex: sequence,
            sequenceIndex: sequence,
            blockKind: kind.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: chapter,
            isHidden: hidden,
            hiddenReason: hidden ? "test" : nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func timeline(
        _ start: TimeInterval,
        _ end: TimeInterval,
        blockID: String,
        chapter: Int? = 0,
        segmentKey: String? = nil
    ) -> ReaderActiveBlockResolver.TimelineRow {
        (start: start, end: end, blockID: blockID, chapterIndex: chapter, segmentKey: segmentKey)
    }
}
