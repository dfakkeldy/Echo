// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationEntitlementCounterTests {
    @Test func segmentTracksCountAsOneNarratedChapter() {
        let tracks = [
            track(id: "syn-book-ch0-s0", path: "/cache/book-ch0-s0-af_heart-v7.m4a"),
            track(id: "syn-book-ch0-s1", path: "/cache/book-ch0-s1-af_heart-v7.m4a"),
            track(id: "syn-book-ch1-s0", path: "/cache/book-ch1-s0-af_heart-v7.m4a"),
        ]

        #expect(NarrationEntitlementCounter.renderedChapterCount(in: tracks) == 2)
    }

    @Test func chapterTracksStillCountNormally() {
        let tracks = [
            track(id: "syn-book-ch0", path: "/cache/book-ch0-af_heart-v7.m4a"),
            track(id: "syn-book-ch1", path: "/cache/book-ch1-af_heart-v7.m4a"),
        ]

        #expect(NarrationEntitlementCounter.renderedChapterCount(in: tracks) == 2)
    }

    private func track(id: String, path: String) -> TrackRecord {
        TrackRecord(
            id: id,
            audiobookID: "book",
            title: "Chapter",
            duration: 1,
            filePath: path,
            isEnabled: true,
            sortOrder: 0,
            playlistPosition: nil,
            narrationVoice: "af_heart")
    }
}
