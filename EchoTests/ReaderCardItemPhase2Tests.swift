// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderCardItemPhase2Tests {
    private func makeBookmark(id: String) -> BookmarkRecord {
        BookmarkRecord(
            id: id, audiobookID: "book-1", trackID: nil, title: "BM",
            mediaTimestamp: 12.0, note: nil, voiceMemoPath: nil, imagePath: nil,
            isEnabled: true, playlistPosition: nil, pdfViewStateJSON: nil,
            latitude: nil, longitude: nil, placeName: nil,
            createdAt: "2026-06-22T00:00:00Z", modifiedAt: "2026-06-22T00:00:00Z")
    }

    private func makeCard(id: String) -> Flashcard {
        Flashcard(
            id: id, audiobookID: "book-1", frontText: "Q", backText: "A",
            mediaTimestamp: 12.0, endTimestamp: nil, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: 0, easeFactor: 2.5, repetitions: 0,
            lastReviewedAt: nil, lastGrade: nil, isEnabled: true, deckID: nil,
            tags: nil, mediaJSON: nil, sourceBlockID: nil, playlistPosition: nil,
            createdAt: nil, modifiedAt: nil, stability: nil, difficulty: nil,
            cardType: "normal", clozeIndex: nil)
    }

    @Test func bookmarkIDIsPrefixedAndUnique() {
        let item = ReaderCardItem.bookmark(makeBookmark(id: "abc"))
        #expect(item.id == "bm-abc")
    }

    @Test func ankiCardIDIsPrefixedAndUnique() {
        let item = ReaderCardItem.ankiCard(makeCard(id: "xyz"))
        #expect(item.id == "fc-xyz")
    }

    @Test func newCasesDoNotCollideWithExistingPrefixes() {
        let ids = Set([
            ReaderCardItem.chapterHeader(title: "T", chapterIndex: 1).id,
            ReaderCardItem.bookmark(makeBookmark(id: "1")).id,
            ReaderCardItem.ankiCard(makeCard(id: "1")).id,
        ])
        #expect(ids.count == 3)
    }

    @Test func equalityAndHashDistinguishCases() {
        let a = ReaderCardItem.bookmark(makeBookmark(id: "1"))
        let b = ReaderCardItem.bookmark(makeBookmark(id: "1"))
        let c = ReaderCardItem.ankiCard(makeCard(id: "1"))
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}
