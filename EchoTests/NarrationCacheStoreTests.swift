// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationCacheStoreTests {
    @Test func selectsThisBooksOtherVoiceFilesForEviction() {
        // bookPrefix matches NarrationFileNaming.chapterPrefix == "{safeID}-ch".
        let files = [
            "book-ch0-af_heart.m4a",  // current voice — keep
            "book-ch1-af_heart.m4a",  // current voice — keep
            "book-ch0-bf_emma.m4a",  // same book, stale voice — evict
            "other-ch0-af_heart.m4a",  // different book — leave alone
        ]
        let stale = NarrationCacheStore.staleVoiceFiles(
            files, bookPrefix: "book-ch", currentVoice: VoiceID("af_heart"))
        #expect(stale == ["book-ch0-bf_emma.m4a"])
    }
}
