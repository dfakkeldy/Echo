// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Book-time resolution for multi-M4B folders (CODE_AUDIT §5.1, §5.20).
///
/// `currentIndex` indexes `state.tracks`, which is independently reorderable via
/// persisted `loadOrder` and user `moveTracks`. `state.m4bBooks` is ALWAYS
/// filename-sorted. Indexing `m4bBooks` by `currentIndex` therefore returns the
/// wrong book once the two orders diverge — these tests pin the URL-resolved fix.
@MainActor
@Suite struct PlaybackBookTimeTests {

    private func book(_ name: String, offset: TimeInterval, duration: TimeInterval) -> M4BBook {
        M4BBook(
            url: URL(string: "file:///lib/\(name).m4b")!,
            title: name, duration: duration, chapters: [],
            cumulativeStartOffset: offset, trackIndex: 0)
    }

    /// §5.1 — after a manual reorder, the playing book's offset must be resolved
    /// by matching the playing track's URL, not by indexing `m4bBooks[currentIndex]`.
    @Test func currentBookStartOffsetResolvesByURLAfterReorder() {
        let state = PlaybackState()
        let a = book("BookA", offset: 0, duration: 100)
        let b = book("BookB", offset: 100, duration: 200)
        // m4bBooks are filename-sorted: A @ 0, B @ 100.
        state.m4bBooks = [a, b]
        // User reordered the playlist so Book B plays first: tracks = [B, A].
        state.tracks = [Track(url: b.url, title: "BookB"), Track(url: a.url, title: "BookA")]
        state.currentIndex = 0  // track 0 is Book B

        // Buggy code returns m4bBooks[0] == Book A's offset (0); correct is B's (100).
        #expect(state.currentBookStartOffset == 100)
    }

    /// A single-file (non-multi-M4B) book has no cumulative offset.
    @Test func currentBookStartOffsetIsZeroForSingleFile() {
        let state = PlaybackState()
        state.tracks = [Track(url: URL(string: "file:///lib/solo.mp3")!, title: "solo")]
        state.currentIndex = 0
        #expect(state.currentBookStartOffset == 0)
    }

    /// §5.20 — book-level progress/sync must use the whole-book duration. For a
    /// multi-M4B book, `durationSeconds` is only the current track, so dividing a
    /// book-absolute time by it yields a fraction > 1 and a premature "finished".
    @Test func effectiveBookDurationIsWholeBookForMultiM4B() {
        let state = PlaybackState()
        state.m4bBooks = [
            book("BookA", offset: 0, duration: 100), book("BookB", offset: 100, duration: 200),
        ]
        state.totalBookDuration = 300
        state.durationSeconds = 100  // current track only

        #expect(state.effectiveBookDuration == 300)
    }

    /// A single-file book's scope duration is just its own track duration.
    @Test func effectiveBookDurationIsTrackForSingleFile() {
        let state = PlaybackState()
        state.durationSeconds = 137

        #expect(state.effectiveBookDuration == 137)
    }

    @Test func bookTimeIndexMapsAbsoluteTimeToTrackOffset() {
        let first = Track(url: URL(string: "file:///lib/01.mp3")!, title: "One")
        let second = Track(url: URL(string: "file:///lib/02.mp3")!, title: "Two")

        let index = PlaybackBookTimeIndex(tracks: [
            .init(trackID: first.id, trackURL: first.url, trackIndex: 0, startTime: 0, duration: 60),
            .init(
                trackID: second.id, trackURL: second.url, trackIndex: 1, startTime: 60,
                duration: 120),
        ])

        #expect(index.totalDuration == 180)
        #expect(index.resolve(bookTime: 75)?.trackID == second.id)
        #expect(index.resolve(bookTime: 75)?.offset == 15)
        #expect(index.resolve(bookTime: 5_000)?.trackID == second.id)
        #expect(index.resolve(bookTime: 5_000)?.offset == 120)
    }

    @Test func playbackStateUsesBookTimeIndexForCurrentAbsoluteTime() {
        let state = PlaybackState()
        let first = Track(url: URL(string: "file:///lib/01.mp3")!, title: "One")
        let second = Track(url: URL(string: "file:///lib/02.mp3")!, title: "Two")
        state.tracks = [first, second]
        state.currentIndex = 1
        state.bookTimeIndex = PlaybackBookTimeIndex(tracks: [
            .init(trackID: first.id, trackURL: first.url, trackIndex: 0, startTime: 0, duration: 60),
            .init(
                trackID: second.id, trackURL: second.url, trackIndex: 1, startTime: 60,
                duration: 120),
        ])

        #expect(state.bookTime(forCurrentTrackOffset: 30) == 90)
        #expect(state.trackOffset(forBookTime: 90, trackID: second.id) == 30)
    }

    @Test func playbackStateFallsBackToM4BBookOffsetWhenNoIndexExists() {
        let state = PlaybackState()
        let a = book("BookA", offset: 0, duration: 100)
        let b = book("BookB", offset: 100, duration: 200)
        state.m4bBooks = [a, b]
        state.tracks = [Track(url: b.url, title: "BookB"), Track(url: a.url, title: "BookA")]
        state.currentIndex = 0

        #expect(state.bookTime(forCurrentTrackOffset: 25) == 125)
    }

    // MARK: - §5.2 next-aggregated-chapter boundary

    private func chapter(_ index: Int, _ start: TimeInterval, _ end: TimeInterval)
        -> AggregatedChapter
    {
        AggregatedChapter(
            bookTitle: "B", bookIndex: 0, chapterTitle: "Ch\(index)", chapterIndex: index,
            startSeconds: start, endSeconds: end,
            sourceBookURL: URL(string: "file:///lib/B.m4b")!)
    }

    /// In the middle of a book, next-chapter advances by one. `globalTime` 150 is
    /// inside chapter index 1 (span 100–200), so the next chapter is index 2.
    @Test func nextAggregatedIndexAdvancesFromMiddle() {
        let chapters = [chapter(0, 0, 100), chapter(1, 100, 200), chapter(2, 200, 300)]
        #expect(PlaybackController.nextAggregatedIndex(chapters: chapters, globalTime: 150) == 2)
    }

    /// §5.2 — sitting inside the final chapter, there is no next chapter; the
    /// helper must return nil rather than looping back to chapter 0.
    @Test func nextAggregatedIndexInFinalChapterHasNoNext() {
        let chapters = [chapter(0, 0, 100), chapter(1, 100, 200)]
        #expect(PlaybackController.nextAggregatedIndex(chapters: chapters, globalTime: 150) == nil)
    }

    /// §5.2 — the core bug: at or past the final chapter's end boundary the old
    /// half-open lookup returned nil → currentIdx -1 → nextIdx 0 → jumped to the
    /// start of the book. The helper must return nil (stay put), not 0.
    @Test func nextAggregatedIndexAtOrPastEndDoesNotLoopToFirst() {
        let chapters = [chapter(0, 0, 100), chapter(1, 100, 200)]
        #expect(PlaybackController.nextAggregatedIndex(chapters: chapters, globalTime: 200) == nil)
        #expect(
            PlaybackController.nextAggregatedIndex(chapters: chapters, globalTime: 5_000) == nil)
    }

    /// Before the first chapter starts, next-chapter targets the first chapter.
    @Test func nextAggregatedIndexBeforeFirstTargetsFirst() {
        let chapters = [chapter(0, 10, 100), chapter(1, 100, 200)]
        #expect(PlaybackController.nextAggregatedIndex(chapters: chapters, globalTime: 0) == 0)
    }
}
