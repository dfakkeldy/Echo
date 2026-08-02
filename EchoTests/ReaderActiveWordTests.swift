// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ReaderActiveWordTests {
    private let rows: [ReaderActiveBlockResolver.WordRow] = [
        (start: 0.0, end: 1.0, blockID: "b0", wordIndex: 0),
        (start: 1.0, end: 2.0, blockID: "b0", wordIndex: 1),
        (start: 2.0, end: 3.0, blockID: "b1", wordIndex: 0),
    ]

    @Test func returnsWordWithinActiveBlock() {
        let w = ReaderActiveBlockResolver.activeWord(in: rows, time: 1.4, activeBlockID: "b0")
        #expect(w == 1)
    }

    @Test func ignoresWordsFromOtherBlocks() {
        // time 2.5 falls in b1's word, but active block is b0 → nil
        #expect(
            ReaderActiveBlockResolver.activeWord(in: rows, time: 2.5, activeBlockID: "b0") == nil)
    }

    @Test func nilWhenNoWordCoversTime() {
        #expect(
            ReaderActiveBlockResolver.activeWord(in: rows, time: 9.0, activeBlockID: "b1") == nil)
    }

    @Test func wordIndexMatchesLinearScanAcrossAllTimes() {
        let rows: [ReaderActiveBlockResolver.WordRow] = [
            (start: 0.0, end: 0.4, blockID: "a", wordIndex: 0),
            (start: 0.4, end: 1.0, blockID: "a", wordIndex: 1),
            (start: 0.0, end: 0.7, blockID: "b", wordIndex: 0),
            (start: 0.7, end: 1.5, blockID: "b", wordIndex: 1),
        ]
        let index = ReaderActiveBlockResolver.WordIndex(rows: rows)
        for t in stride(from: -0.1, through: 1.6, by: 0.05) {
            for block in ["a", "b", "missing"] {
                #expect(
                    ReaderActiveBlockResolver.activeWord(
                        in: index, time: t, activeBlockID: block)
                        == ReaderActiveBlockResolver.activeWord(
                            in: rows, time: t, activeBlockID: block))
            }
        }
        #expect(
            ReaderActiveBlockResolver.activeWord(in: index, time: 0.5, activeBlockID: nil) == nil)
    }
}
