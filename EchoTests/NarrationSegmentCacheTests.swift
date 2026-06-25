// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationSegmentCacheTests {
    private let audiobookID = "book_id"
    private let voice = VoiceID("af_heart")

    @Test func cachedChapterReturnsPlannedSegmentURLsInOrder() {
        let planned = [
            segment(0, chapterDisplayNumber: 1),
            segment(1, chapterDisplayNumber: 1),
            segment(2, chapterDisplayNumber: 1),
        ]
        let files = [
            file("cover.jpg"),
            file(segmentFileName(chapter: 0, segment: 2, voice: voice)),
            file(segmentFileName(chapter: 0, segment: 0, voice: voice)),
            file(segmentFileName(chapter: 0, segment: 1, voice: VoiceID("bf_emma"))),
            file(segmentFileName(chapter: 1, segment: 0, voice: voice)),
            file(segmentFileName(chapter: 0, segment: 1, voice: voice)),
        ]

        let cached = NarrationSegmentCache.cachedChapter(
            for: planned,
            files: files,
            audiobookID: audiobookID,
            voice: voice)

        #expect(cached?.chapterIndex == 0)
        #expect(cached?.chapterDisplayNumber == 1)
        #expect(cached?.segmentURLs.map(\.lastPathComponent) == [
            segmentFileName(chapter: 0, segment: 0, voice: voice),
            segmentFileName(chapter: 0, segment: 1, voice: voice),
            segmentFileName(chapter: 0, segment: 2, voice: voice),
        ])
    }

    @Test func cachedChapterReturnsNilWhenAnyPlannedSegmentIsMissing() {
        let planned = [
            segment(0, chapterDisplayNumber: 1),
            segment(1, chapterDisplayNumber: 1),
        ]
        let files = [
            file(segmentFileName(chapter: 0, segment: 0, voice: voice))
        ]

        let cached = NarrationSegmentCache.cachedChapter(
            for: planned,
            files: files,
            audiobookID: audiobookID,
            voice: voice)

        #expect(cached == nil)
    }

    @Test func cachedChapterReturnsNilForEmptyPlans() {
        let cached = NarrationSegmentCache.cachedChapter(
            for: [],
            files: [],
            audiobookID: audiobookID,
            voice: voice)

        #expect(cached == nil)
    }

    private func segment(
        _ segmentIndex: Int,
        chapterDisplayNumber: Int
    ) -> NarrationSegmentPlanner.PlannedSegment {
        NarrationSegmentPlanner.PlannedSegment(
            chapterIndex: 0,
            chapterDisplayNumber: chapterDisplayNumber,
            segmentIndex: segmentIndex,
            blocks: [])
    }

    private func segmentFileName(chapter: Int, segment: Int, voice: VoiceID) -> String {
        NarrationFileNaming.segmentFileName(
            audiobookID: audiobookID,
            chapterIndex: chapter,
            segmentIndex: segment,
            voice: voice)
    }

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }
}
