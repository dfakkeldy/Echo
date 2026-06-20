// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import Foundation
    import Testing

    @testable import Echo

    @Suite struct NarrationOutlineModelTests {
        @Test func classifierFlagsAudiolessAndNarrationCacheBooks() {
            let cache = "/Library/App/Narration"
            // Audio-less EPUB (no tracks yet) → narration book.
            #expect(
                NarrationBookClassifier.isNarrationBook(
                    hasEPUB: true, trackPaths: [], narrationCachePath: cache) == true)
            // Tracks that are narration-cache files → still a narration book.
            #expect(
                NarrationBookClassifier.isNarrationBook(
                    hasEPUB: true, trackPaths: ["\(cache)/syn-bk-ch0.m4a"],
                    narrationCachePath: cache) == true)
            // Imported audiobook (tracks outside the narration cache) → NOT.
            #expect(
                NarrationBookClassifier.isNarrationBook(
                    hasEPUB: true, trackPaths: ["/Users/me/Books/ch1.mp3"],
                    narrationCachePath: cache) == false)
            // No EPUB → NOT.
            #expect(
                NarrationBookClassifier.isNarrationBook(
                    hasEPUB: false, trackPaths: [], narrationCachePath: cache) == false)
        }
    }
#endif
