// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct FeedItemInjectorTests {
    private func block(_ id: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "bk1", spineHref: "c.xhtml", spineIndex: 0,
            blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
            text: "t", htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
    }

    private func note(_ id: String, block blockID: String) -> NoteRecord {
        NoteRecord(
            id: id, audiobookID: "bk1", text: "n", mediaTimestamp: 0,
            realTimestamp: nil, isEnabled: true, playlistPosition: nil,
            createdAt: "t", modifiedAt: "t", epubBlockID: blockID)
    }

    private func memo(_ id: String, block blockID: String) -> VoiceMemoRecord {
        VoiceMemoRecord(
            id: id, audiobookID: "bk1", epubBlockID: blockID,
            mediaTimestamp: 0, filePath: "x.m4a", duration: nil,
            isEnabled: true, createdAt: "t", modifiedAt: "t")
    }

    @Test func noteIsInsertedRightAfterItsBlock() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: ["Chapter 1"],
            items: [.block(block("b1")), .block(block("b2"))])
        let result = FeedItemInjector.inject(
            into: [section],
            notesByBlockID: ["b1": [note("n1", block: "b1")]],
            memosByBlockID: [:])
        #expect(result.first?.items.map(\.id) == ["b-b1", "note-n1", "b-b2"])
    }

    @Test func memoFollowsNoteWhenBothAnchorSameBlock() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: [],
            items: [.block(block("b1"))])
        let result = FeedItemInjector.inject(
            into: [section],
            notesByBlockID: ["b1": [note("n1", block: "b1")]],
            memosByBlockID: ["b1": [memo("m1", block: "b1")]])
        #expect(result.first?.items.map(\.id) == ["b-b1", "note-n1", "vm-m1"])
    }

    @Test func unanchoredItemsAreDropped() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: [],
            items: [.block(block("b1"))])
        let result = FeedItemInjector.inject(
            into: [section],
            notesByBlockID: ["bX": [note("n1", block: "bX")]],
            memosByBlockID: [:])
        #expect(result.first?.items.map(\.id) == ["b-b1"])
    }

    @Test func headerOnlySectionIsUnchanged() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: ["Chapter 1"],
            items: [.chapterHeader(title: "Chapter 1", chapterIndex: 0)])
        let result = FeedItemInjector.inject(
            into: [section], notesByBlockID: [:], memosByBlockID: [:])
        #expect(result.first?.items.map(\.id) == ["ch-0"])
    }

    // C2 regression: multi-section chapter — note in s0, memo in s1, neither duplicated
    @Test func multiSectionChapterPlacesItemsInCorrectSectionWithNoDuplicateIDs() {
        let s0 = ReaderCardSection(
            id: "ch0-s0", headingStack: ["Chapter 1"],
            items: [.block(block("b1")), .block(block("b2"))])
        let s1 = ReaderCardSection(
            id: "ch0-s1", headingStack: ["Chapter 1", "Section 1.1"],
            items: [.block(block("b3")), .block(block("b4"))])

        let result = FeedItemInjector.inject(
            into: [s0, s1],
            notesByBlockID: ["b1": [note("n1", block: "b1")]],
            memosByBlockID: ["b3": [memo("m1", block: "b3")]])

        let s0Result = result[0]
        let s1Result = result[1]

        // Note appears only in s0, after b1
        #expect(s0Result.items.map(\.id) == ["b-b1", "note-n1", "b-b2"])
        // Memo appears only in s1, after b3
        #expect(s1Result.items.map(\.id) == ["b-b3", "vm-m1", "b-b4"])

        // No duplicate IDs across entire result
        let allIDs = result.flatMap { $0.items.map(\.id) }
        #expect(Set(allIDs).count == allIDs.count)
    }
}
