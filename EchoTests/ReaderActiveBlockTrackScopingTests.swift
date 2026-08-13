// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Tests for **Layer 1** of the multi-file read-along fix: the reader must
/// resolve the active/highlighted block within the *currently-playing track*,
/// not by binary-searching a whole-book time axis with a per-track 0-based
/// playback time.
///
/// The core regression these guard against: a multi-file book whose tracks each
/// expose a per-track 0-based `currentTime`. Two different tracks both report
/// `time == 5.0`; without track scoping the reader resolves both to the *first*
/// matching row on the global axis, so the highlight is stuck in chapter 0 no
/// matter which track is playing.
///
/// Two layers of coverage:
///   1. `ReaderActiveBlockResolver` — the pure, shared EchoCore helper that both
///      iOS (`ReaderFeedViewModel`) and macOS (`MacReaderFeedView`) delegate to.
///   2. `ReaderFeedViewModel.updateActiveBlock(time:currentTrackChapterIndices:)`
///      end-to-end via the `DatabaseService(inMemory:)` + `reload()` seam.
@MainActor
struct ReaderActiveBlockTrackScopingTests {

    // MARK: - Fixtures

    private func makeBlock(
        id: String,
        seq: Int,
        chapterIndex: Int?,
        kind: EPubBlockRecord.Kind = .paragraph,
        text: String = "Lorem ipsum dolor sit amet."
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "book-1",
            spineHref: "s\((chapterIndex ?? 0)).xhtml",
            spineIndex: chapterIndex ?? 0,
            blockIndex: seq,
            sequenceIndex: seq,
            blockKind: kind.rawValue,
            text: text,
            chapterIndex: chapterIndex,
            isHidden: false,
            wordCount: 5
        )
    }

    private func makeDatabase() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        return db
    }

    /// Inserts a raw `timeline_item` row pointing at `blockID` over `[start, end)`.
    private func insertTimeline(
        _ db: DatabaseService,
        id: String,
        blockID: String,
        start: TimeInterval,
        end: TimeInterval,
        segmentKey: String? = nil,
        status: String = "auto"
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                        (id, audiobook_id, item_type, title, audio_start_time, audio_end_time, epub_block_id, segment_key, alignment_status)
                    VALUES (?, 'book-1', 'paragraph', 'x', ?, ?, ?, ?, ?)
                    """,
                arguments: [id, start, end, blockID, segmentKey, status]
            )
        }
    }

    // MARK: - Pure helper: direct unit tests

    /// A `nil` scoping set means "no scoping" — whole-book behavior, identical to
    /// the legacy binary search. Used for single-track books so they are a strict
    /// no-op.
    @Test func helperNilScopeResolvesWholeBook() {
        let cache: [ReaderActiveBlockResolver.TimelineRow] = [
            (0, 5, "a", 0, nil),
            (5, 10, "b", 0, nil),
            (10, 15, "c", 0, nil),
        ]
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 7, currentTrackChapterIndices: nil) == "b")
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 0, currentTrackChapterIndices: nil) == "a")
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 14.9, currentTrackChapterIndices: nil) == "c")
        // [start, end) — exactly at end belongs to the next row.
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 5, currentTrackChapterIndices: nil) == "b")
        // Out of range.
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 100, currentTrackChapterIndices: nil) == nil)
    }

    /// THE core regression, at the pure-helper level: colliding per-track times in
    /// two chapters must resolve to the chapter named by the scoping set.
    @Test func helperScopedCollidingTimesResolveByTrack() {
        // Chapter 0 and chapter 1 both expose blocks at the *same* per-track
        // times {0,5,10}. On the global axis they are interleaved by start time.
        let cache: [ReaderActiveBlockResolver.TimelineRow] = [
            (0, 5, "c0-a", 0, nil),
            (0, 5, "c1-a", 1, nil),
            (5, 10, "c0-b", 0, nil),
            (5, 10, "c1-b", 1, nil),
            (10, 15, "c0-c", 0, nil),
            (10, 15, "c1-c", 1, nil),
        ]
        // Track 0 playing at t=5 → a chapter-0 block.
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 5, currentTrackChapterIndices: [0]) == "c0-b")
        // Track 1 playing at the SAME t=5 → a chapter-1 block.
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 5, currentTrackChapterIndices: [1]) == "c1-b")
    }

    /// Segment files reset their per-track time to 0 within the SAME chapter, so
    /// chapter-only scoping is insufficient: segment 0 and segment 1 can both have
    /// a block at t=2 in chapter 0. The segment key wins when present.
    @Test func helperSegmentScopeResolvesSameChapterSegmentCollisions() {
        let cache: [ReaderActiveBlockResolver.TimelineRow] = [
            (0, 5, "seg0-block", 0, "0-0"),
            (0, 5, "seg1-block", 0, "0-1"),
        ]

        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache,
                time: 2,
                currentTrackSegmentKey: ReaderActiveBlockResolver.segmentKey(
                    forChapter: 0,
                    segment: 1),
                currentTrackChapterIndices: [0]) == "seg1-block")
    }

    @Test func segmentKeyFormatIsSharedByWriterAndReader() {
        #expect(ReaderActiveBlockResolver.segmentKey(forChapter: 12, segment: 3) == "12-3")
    }

    /// `nil`-chapter rows (front matter) belong to track 0 only — never collide
    /// into a later track's scope.
    @Test func helperNullChapterBelongsToTrackZeroOnly() {
        let cache: [ReaderActiveBlockResolver.TimelineRow] = [
            (0, 5, "front", nil, nil),  // front matter, no chapter index
            (0, 5, "c1-a", 1, nil),
        ]
        // Track 0 scope includes the nil-chapter front-matter block.
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 2, currentTrackChapterIndices: [0]) == "front")
        // Track 1 scope must NOT see the nil-chapter block; it sees its own.
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 2, currentTrackChapterIndices: [1]) == "c1-a")
    }

    // MARK: - Pure helper: trackChapterScope (which chapter(s) the queue is on)

    /// Narration resume / dropped-chapter gap: the playing track is chapter 3 even
    /// though it sits at queue position 0 (the plan was front-truncated on resume,
    /// or an image-only chapter was dropped). Scope MUST follow the playing chapter
    /// (3), NOT the queue position (0) — the latter would mis-highlight or blank.
    @Test func trackChapterScopeNarrationResumeFollowsPlayingChapter() {
        #expect(
            ReaderActiveBlockResolver.trackChapterScope(
                trackCount: 4, isMultiM4B: false, currentIndex: 0, playingChapterIndex: 3) == [3])
    }

    /// MP3-folder (no narration filename to parse): track position already equals
    /// the EPUB chapter index 1:1, so with `playingChapterIndex == nil` the scope
    /// falls back to `{currentIndex}`.
    @Test func trackChapterScopeMP3FolderFallsBackToCurrentIndex() {
        #expect(
            ReaderActiveBlockResolver.trackChapterScope(
                trackCount: 5, isMultiM4B: false, currentIndex: 2, playingChapterIndex: nil) == [2])
    }

    /// Single track with NO known playing chapter → no scoping (whole-book legacy
    /// axis). `playingChapterIndex` is `nil` here precisely because there is no
    /// narration filename to parse, so a single continuous axis is correct.
    @Test func trackChapterScopeSingleTrackUnknownChapterIsNil() {
        #expect(
            ReaderActiveBlockResolver.trackChapterScope(
                trackCount: 1, isMultiM4B: false, currentIndex: 0, playingChapterIndex: nil) == nil)
    }

    /// Forward-only narration resume injects a SINGLE track that is still its real
    /// chapter (parsed from the `ch{N}` filename). Even though `trackCount == 1`,
    /// the scope MUST follow the playing chapter (4) — the prior whole-book
    /// fallback caused the reader to highlight front matter instead of chapter 4.
    @Test func trackChapterScopeSingleResumedTrackFollowsPlayingChapter() {
        #expect(
            ReaderActiveBlockResolver.trackChapterScope(
                trackCount: 1, isMultiM4B: false, currentIndex: 0, playingChapterIndex: 4) == [4])
    }

    /// Multi-M4B → no scoping: an .m4b aggregates many chapters whose per-book index
    /// does not reliably map onto the EPUB global `chapter_index`, so fall back to
    /// the whole-book axis rather than risk mis-scoping. Multi-M4B always passes
    /// `playingChapterIndex == nil` (there is no narration filename to parse), so
    /// that is the canonical input here.
    @Test func trackChapterScopeMultiM4BIsNil() {
        #expect(
            ReaderActiveBlockResolver.trackChapterScope(
                trackCount: 6, isMultiM4B: true, currentIndex: 2, playingChapterIndex: nil) == nil)
    }

    /// A multi-m4b style scope holding a *range* of chapter indices considers all
    /// of them.
    @Test func helperScopeWithMultipleChapters() {
        let cache: [ReaderActiveBlockResolver.TimelineRow] = [
            (0, 5, "c2-a", 2, nil),
            (5, 10, "c3-a", 3, nil),
            (5, 10, "c5-a", 5, nil),
        ]
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 0, currentTrackChapterIndices: [2, 3]) == "c2-a")
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 7, currentTrackChapterIndices: [2, 3]) == "c3-a")
        // Chapter 5 is not in scope → not resolved even though its time matches.
        #expect(
            ReaderActiveBlockResolver.activeBlockID(
                in: cache, time: 7, currentTrackChapterIndices: [5]) == "c5-a")
    }

    // MARK: - End-to-end via ReaderFeedViewModel

    /// (a) Single track is a strict no-op: one chapter resolves exactly as the
    /// legacy whole-book search did when scope is `nil`.
    @Test func singleTrackIsNoOp() throws {
        let db = try makeDatabase()
        try EPubBlockDAO(db: db.writer).insertAll([
            makeBlock(id: "b0", seq: 0, chapterIndex: 0),
            makeBlock(id: "b1", seq: 1, chapterIndex: 0),
            makeBlock(id: "b2", seq: 2, chapterIndex: 0),
        ])
        try insertTimeline(db, id: "ti0", blockID: "b0", start: 0, end: 5)
        try insertTimeline(db, id: "ti1", blockID: "b1", start: 5, end: 10)
        try insertTimeline(db, id: "ti2", blockID: "b2", start: 10, end: 15)

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        vm.updateActiveBlock(time: 7, currentTrackChapterIndices: nil)
        #expect(vm.activeBlockID == "b1")
        vm.updateActiveBlock(time: 12, currentTrackChapterIndices: nil)
        #expect(vm.activeBlockID == "b2")
    }

    /// (b) THE core regression end-to-end: chapter 0 blocks at {0,5,10} and
    /// chapter 1 blocks ALSO at {0,5,10}. Resolving t=5 with current track 0
    /// must land on a chapter-0 block; with current track 1, a chapter-1 block.
    @Test func narrationLikeTwoChaptersCollidingTimes() throws {
        let db = try makeDatabase()
        try EPubBlockDAO(db: db.writer).insertAll([
            makeBlock(id: "c0-a", seq: 0, chapterIndex: 0),
            makeBlock(id: "c0-b", seq: 1, chapterIndex: 0),
            makeBlock(id: "c0-c", seq: 2, chapterIndex: 0),
            makeBlock(id: "c1-a", seq: 3, chapterIndex: 1),
            makeBlock(id: "c1-b", seq: 4, chapterIndex: 1),
            makeBlock(id: "c1-c", seq: 5, chapterIndex: 1),
        ])
        // Per-track 0-based times collide across the two chapters.
        try insertTimeline(db, id: "ti0a", blockID: "c0-a", start: 0, end: 5)
        try insertTimeline(db, id: "ti0b", blockID: "c0-b", start: 5, end: 10)
        try insertTimeline(db, id: "ti0c", blockID: "c0-c", start: 10, end: 15)
        try insertTimeline(db, id: "ti1a", blockID: "c1-a", start: 0, end: 5)
        try insertTimeline(db, id: "ti1b", blockID: "c1-b", start: 5, end: 10)
        try insertTimeline(db, id: "ti1c", blockID: "c1-c", start: 10, end: 15)

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        vm.updateActiveBlock(time: 5, currentTrackChapterIndices: [0])
        #expect(vm.activeBlockID == "c0-b")

        vm.updateActiveBlock(time: 5, currentTrackChapterIndices: [1])
        #expect(vm.activeBlockID == "c1-b")
    }

    @Test func segmentScopedSameChapterCollidingTimes() throws {
        let db = try makeDatabase()
        try EPubBlockDAO(db: db.writer).insertAll([
            makeBlock(id: "seg0-block", seq: 0, chapterIndex: 0),
            makeBlock(id: "seg1-block", seq: 1, chapterIndex: 0),
        ])
        try insertTimeline(
            db,
            id: "ti-seg0",
            blockID: "seg0-block",
            start: 0,
            end: 5,
            segmentKey: "0-0")
        try insertTimeline(
            db,
            id: "ti-seg1",
            blockID: "seg1-block",
            start: 0,
            end: 5,
            segmentKey: "0-1")

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        vm.updateActiveBlock(
            time: 2,
            currentTrackSegmentKey: "0-1",
            currentTrackChapterIndices: [0])

        #expect(vm.activeBlockID == "seg1-block")
    }

    /// (c) Switching the current track re-resolves into the new track at the same
    /// per-track time.
    @Test func trackBoundaryTransition() throws {
        let db = try makeDatabase()
        try EPubBlockDAO(db: db.writer).insertAll([
            makeBlock(id: "c0-a", seq: 0, chapterIndex: 0),
            makeBlock(id: "c1-a", seq: 1, chapterIndex: 1),
            makeBlock(id: "c2-a", seq: 2, chapterIndex: 2),
        ])
        try insertTimeline(db, id: "ti0", blockID: "c0-a", start: 0, end: 5)
        try insertTimeline(db, id: "ti1", blockID: "c1-a", start: 0, end: 5)
        try insertTimeline(db, id: "ti2", blockID: "c2-a", start: 0, end: 5)

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        vm.updateActiveBlock(time: 2, currentTrackChapterIndices: [0])
        #expect(vm.activeBlockID == "c0-a")
        // Track advances; same per-track time t=2.
        vm.updateActiveBlock(time: 2, currentTrackChapterIndices: [1])
        #expect(vm.activeBlockID == "c1-a")
        vm.updateActiveBlock(time: 2, currentTrackChapterIndices: [2])
        #expect(vm.activeBlockID == "c2-a")
    }

    /// (d) A nil-chapter front-matter block resolves only under track 0 and never
    /// collides into a later track.
    @Test func nullChapterIndexFallback() throws {
        let db = try makeDatabase()
        try EPubBlockDAO(db: db.writer).insertAll([
            makeBlock(id: "front", seq: 0, chapterIndex: nil),
            makeBlock(id: "c1-a", seq: 1, chapterIndex: 1),
        ])
        try insertTimeline(db, id: "tiF", blockID: "front", start: 0, end: 5)
        try insertTimeline(db, id: "ti1", blockID: "c1-a", start: 0, end: 5)

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        // Track 0 sees the front-matter block.
        vm.updateActiveBlock(time: 2, currentTrackChapterIndices: [0])
        #expect(vm.activeBlockID == "front")
        // Track 1 must NOT inherit the nil-chapter front-matter block.
        vm.updateActiveBlock(time: 2, currentTrackChapterIndices: [1])
        #expect(vm.activeBlockID == "c1-a")
    }

    /// The "is-this-block-timestamped" alignment badge must be gated to the
    /// current track: a 5.0s anchor in chapter 1 must not light up a chapter-0
    /// block that also happens to have a 5.0s anchor.
    @Test func alignmentBadgeIsTrackScoped() throws {
        let db = try makeDatabase()
        try EPubBlockDAO(db: db.writer).insertAll([
            makeBlock(id: "c0-a", seq: 0, chapterIndex: 0),
            makeBlock(id: "c1-a", seq: 1, chapterIndex: 1),
        ])
        try insertTimeline(db, id: "ti0", blockID: "c0-a", start: 5, end: 10)
        try insertTimeline(db, id: "ti1", blockID: "c1-a", start: 5, end: 10)

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        // Scoping to track 1 → only the chapter-1 block reads as aligned.
        vm.updateActiveBlock(time: 6, currentTrackChapterIndices: [1])
        #expect(vm.audioStartTimeByBlockID["c1-a"] != nil)
        #expect(vm.audioStartTimeByBlockID["c0-a"] == nil)
    }
}
