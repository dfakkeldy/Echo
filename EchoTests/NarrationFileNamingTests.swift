// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationFileNamingTests {
    @Test func parsesChapterIndexFromFileName() {
        // Format: "{safeID}-ch{N}-{voice}.m4a" — safeID has no '-' (safeToken maps
        // non-alphanumerics to '_'), so "-ch" only marks the chapter separator.
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book_id-ch0-af_heart.m4a") == 0)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "x_y-ch12-bf_emma.m4a") == 12)
    }

    @Test func returnsNilForNonNarrationFileName() {
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "cover.jpg") == nil)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book-noch-af_heart.m4a") == nil)
    }

    @Test func segmentFileNameRoundTrips() {
        let name = NarrationFileNaming.segmentFileName(
            audiobookID: "file:///b/", chapterIndex: 3, segmentIndex: 2,
            voice: VoiceID("af_heart"))

        #expect(name.contains("-ch3-s2-af_heart-v\(NarrationFileNaming.renderVersion).m4a"))
        let location = NarrationFileNaming.segmentLocation(fromFileName: name)
        #expect(location?.chapterIndex == 3)
        #expect(location?.segmentIndex == 2)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: name) == 3)
    }

    @Test func segmentLocationRejectsNonSegmentNames() {
        #expect(NarrationFileNaming.segmentLocation(fromFileName: "nope.m4a") == nil)
        #expect(
            NarrationFileNaming.segmentLocation(
                fromFileName: "book_id-ch0-af_heart-v\(NarrationFileNaming.renderVersion).m4a")
                == nil)
    }
}
