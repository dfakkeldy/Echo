// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct FeedFilterModelTests {

    @Test func everythingMatchesEveryChapter() {
        #expect(FeedContentType.everything.matchesChapter(hasAudio: true))
        #expect(FeedContentType.everything.matchesChapter(hasAudio: false))
    }

    @Test func audioMatchesOnlyChaptersWithAudio() {
        #expect(FeedContentType.audio.matchesChapter(hasAudio: true))
        #expect(!FeedContentType.audio.matchesChapter(hasAudio: false))
    }

    @Test func textMatchesOnlyChaptersWithoutAudio() {
        #expect(!FeedContentType.text.matchesChapter(hasAudio: true))
        #expect(FeedContentType.text.matchesChapter(hasAudio: false))
    }

    @Test func chapterLevelFiltersAcceptWholeChapter() {
        // Pics / Pics+Audio / Bookmarks / Cards do NOT drop whole chapters;
        // they filter at the block level (matchesChapter is always true so the
        // group survives to be item-filtered).
        for t in [FeedContentType.pics, .picsAndAudio, .bookmarks, .cards] {
            #expect(t.matchesChapter(hasAudio: true))
            #expect(t.matchesChapter(hasAudio: false))
        }
    }

    @Test func picsMatchesOnlyImageBlocks() {
        #expect(FeedContentType.pics.matchesBlockKind("image", hasAudio: false))
        #expect(!FeedContentType.pics.matchesBlockKind("paragraph", hasAudio: false))
        #expect(!FeedContentType.pics.matchesBlockKind("heading", hasAudio: true))
    }

    @Test func picsAndAudioMatchesImageBlocksInAudioChapters() {
        #expect(FeedContentType.picsAndAudio.matchesBlockKind("image", hasAudio: true))
        #expect(!FeedContentType.picsAndAudio.matchesBlockKind("image", hasAudio: false))
        #expect(!FeedContentType.picsAndAudio.matchesBlockKind("paragraph", hasAudio: true))
    }

    @Test func everythingMatchesEveryBlock() {
        #expect(FeedContentType.everything.matchesBlockKind("paragraph", hasAudio: false))
        #expect(FeedContentType.everything.matchesBlockKind("image", hasAudio: true))
    }

    @Test func audioAndTextDoNotItemFilter() {
        // Audio/Text are chapter-level only; once a chapter survives, every block in it stays.
        for t in [FeedContentType.audio, .text] {
            #expect(t.matchesBlockKind("paragraph", hasAudio: true))
            #expect(t.matchesBlockKind("image", hasAudio: false))
        }
    }

    @Test func defaultFilterIsEverythingWholeBook() {
        let f = FeedFilter()
        #expect(f.contentType == .everything)
        #expect(f.scope == .wholeBook)
    }

    @Test func filterEquatableByBothAxes() {
        #expect(
            FeedFilter(contentType: .audio, scope: .wholeBook)
                == FeedFilter(contentType: .audio, scope: .wholeBook))
        #expect(
            FeedFilter(contentType: .audio, scope: .wholeBook)
                != FeedFilter(contentType: .text, scope: .wholeBook))
        #expect(
            FeedFilter(contentType: .audio, scope: .wholeBook)
                != FeedFilter(contentType: .audio, scope: .lastSession))
    }

    @Test func allContentTypesAreEnumerable() {
        // Drives the chip row; assert the full set so a new case forces a chip update.
        #expect(
            FeedContentType.allCases == [
                .everything, .audio, .text, .pics, .picsAndAudio, .bookmarks, .cards,
            ])
    }
}
