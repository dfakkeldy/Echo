// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationCacheStoreTests {
    @Test func selectsThisBooksStaleVoiceAndVersionFilesForEviction() {
        // bookPrefix matches NarrationFileNaming.chapterPrefix == "{safeID}-ch".
        // Keep only the current voice AT the current render version; sweep stale
        // voices AND orphaned older renders (the un-versioned v1 files).
        let v = NarrationFileNaming.renderVersion
        let files = [
            "book-ch0-af_heart-v\(v).m4a",  // current voice + version — keep
            "book-ch1-af_heart-v\(v).m4a",  // current voice + version — keep
            "book-ch0-bf_emma-v\(v).m4a",  // same book, stale voice — evict
            "book-ch0-af_heart.m4a",  // current voice, OLD (un-versioned) render — evict
            "other-ch0-af_heart-v\(v).m4a",  // different book — leave alone
        ]
        let stale = NarrationCacheStore.staleVoiceFiles(
            files, bookPrefix: "book-ch", currentVoice: VoiceID("af_heart"))
        #expect(
            Set(stale) == Set(["book-ch0-bf_emma-v\(v).m4a", "book-ch0-af_heart.m4a"]))
    }
}
