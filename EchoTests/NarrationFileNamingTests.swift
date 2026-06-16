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
}
