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
}
