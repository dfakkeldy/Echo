// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Verifies the pure chapter-index math that `MacPlayerModel` delegates to.
/// `MacPlayerModel` itself is in the `Echo macOS` target and is not reachable
/// from this test target, so the math is exercised here against the shared
/// `ChapterService`, and the Mac wiring is verified structurally elsewhere.
struct ChapterServiceNavigationTests {

    /// Three back-to-back chapters: [0,10) [10,20) [20,30).
    private func makeChapters() -> [Chapter] {
        [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            Chapter(index: 2, title: "Three", startSeconds: 20, endSeconds: 30),
        ]
    }

    @Test func chapterIndexForTimeIsHalfOpenInterval() {
        let chapters = makeChapters()
        #expect(ChapterService.chapterIndex(forTime: 10, in: chapters) == 1)
        #expect(ChapterService.chapterIndex(forTime: 15, in: chapters) == 1)
        #expect(ChapterService.chapterIndex(forTime: 20, in: chapters) == 2)
        #expect(ChapterService.chapterIndex(forTime: 0, in: chapters) == 0)
    }

    @Test func chapterIndexBeyondLastChapterIsNil() {
        let chapters = makeChapters()
        #expect(ChapterService.chapterIndex(forTime: 30, in: chapters) == nil)
        #expect(ChapterService.chapterIndex(forTime: 99, in: chapters) == nil)
    }

    @Test func singleChapterListIsTreatedAsNoChapters() {
        let one = [Chapter(index: 0, title: "Solo", startSeconds: 0, endSeconds: 30)]
        #expect(ChapterService.chapterIndex(forTime: 5, in: one) == nil)
    }

    @Test func chapterIndexTracksPlayheadAcrossBoundaries() {
        let chapters = makeChapters()
        // Simulate the observer sampling currentTime as playback advances.
        let samples: [(time: Double, expected: Int?)] = [
            (0.0, 0), (9.99, 0), (10.0, 1), (19.5, 1), (20.0, 2), (29.99, 2),
        ]
        for sample in samples {
            #expect(
                ChapterService.chapterIndex(forTime: sample.time, in: chapters) == sample.expected,
                "time \(sample.time) should map to chapter \(String(describing: sample.expected))"
            )
        }
        // Seeking backward re-derives a lower index (no monotonic-only assumption).
        #expect(ChapterService.chapterIndex(forTime: 5.0, in: chapters) == 0)
    }
}
