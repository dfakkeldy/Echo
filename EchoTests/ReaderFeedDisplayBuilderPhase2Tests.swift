// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderFeedDisplayBuilderPhase2Tests {
    // D3 fix: `EPubBlockRecord` has no `blockType:` or `level:` labels; the real
    // memberwise init requires `spineHref`, `spineIndex`, `blockIndex`, `blockKind`
    // (all non-optional, no defaults). Use the correct full memberwise init.
    private func block(_ id: String, seq: Int) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book-1",
            spineHref: "ch0.xhtml", spineIndex: 0, blockIndex: seq,
            sequenceIndex: seq, blockKind: "paragraph",
            text: "t", htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: "2026-06-22T00:00:00Z", modifiedAt: "2026-06-22T00:00:00Z")
    }

    private func bookmark(_ id: String) -> ReaderCardItem {
        .bookmark(
            BookmarkRecord(
                id: id, audiobookID: "book-1", trackID: nil, title: "BM",
                mediaTimestamp: 1, note: nil, voiceMemoPath: nil, imagePath: nil,
                isEnabled: true, playlistPosition: nil, pdfViewStateJSON: nil,
                latitude: nil, longitude: nil, placeName: nil,
                createdAt: "2026-06-22T00:00:00Z", modifiedAt: "2026-06-22T00:00:00Z"))
    }

    @Test func extraAnchoredToBlockSortsRightAfterIt() {
        let items: [ReaderCardItem] = [
            .block(block("a", seq: 0)), .block(block("b", seq: 1)),
        ]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: "a")])
        #expect(result.map(\.id) == ["b-a", "bm-bm1", "b-b"])
    }

    @Test func unanchoredExtraSortsToEnd() {
        let items: [ReaderCardItem] = [
            .block(block("a", seq: 0)), .block(block("b", seq: 1)),
        ]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: nil)])
        #expect(result.map(\.id) == ["b-a", "b-b", "bm-bm1"])
    }

    @Test func multipleExtrasAfterSameBlockKeepStableOrder() {
        let items: [ReaderCardItem] = [.block(block("a", seq: 0))]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [
                .init(item: bookmark("bm1"), afterBlockID: "a"),
                .init(item: bookmark("bm2"), afterBlockID: "a"),
            ])
        #expect(result.map(\.id) == ["b-a", "bm-bm1", "bm-bm2"])
    }

    @Test func anchorToUnknownBlockFallsBackToEnd() {
        let items: [ReaderCardItem] = [.block(block("a", seq: 0))]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: "ghost")])
        #expect(result.map(\.id) == ["b-a", "bm-bm1"])
    }

    @Test func chapterHeaderStaysFirst() {
        let items: [ReaderCardItem] = [
            .chapterHeader(title: "Chapter One", chapterIndex: 0),
            .block(block("a", seq: 0)),
        ]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: "a")])
        #expect(result.map(\.id) == ["ch-0", "b-a", "bm-bm1"])
    }
}
