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

    /// Legacy `activeWord(in: [WordRow], …)` returns the FIRST row in array
    /// order containing `time`. Word timings are not guaranteed disjoint (no
    /// DB constraint enforces it, and this repo has shipped timing anomalies
    /// before), so the index must reproduce first-match-in-original-order
    /// semantics, not assume sorted/non-overlapping ranges.
    @Test func wordIndexMatchesLinearScanForOverlappingAndNestedRanges() {
        let rows: [ReaderActiveBlockResolver.WordRow] = [
            (start: 0, end: 10, blockID: "x", wordIndex: 0),
            (start: 1, end: 2, blockID: "x", wordIndex: 1),
            (start: 3, end: 4, blockID: "x", wordIndex: 2),
        ]
        let index = ReaderActiveBlockResolver.WordIndex(rows: rows)
        for t in stride(from: -0.5, through: 10.5, by: 0.25) {
            #expect(
                ReaderActiveBlockResolver.activeWord(in: index, time: t, activeBlockID: "x")
                    == ReaderActiveBlockResolver.activeWord(in: rows, time: t, activeBlockID: "x"),
                "mismatch at t=\(t)")
        }
        // Explicit worked example from the counter-example that motivated this
        // test: at t=3.5 both B (1...2) and C (3...4) are out, only A (0...10)
        // covers it — but a naive binary search over start-sorted rows can
        // land on C first and wrongly report wordIndex 2 instead of 0.
        #expect(ReaderActiveBlockResolver.activeWord(in: rows, time: 3.5, activeBlockID: "x") == 0)
        #expect(ReaderActiveBlockResolver.activeWord(in: index, time: 3.5, activeBlockID: "x") == 0)
    }

    @Test func wordIndexMatchesLinearScanAcrossGapsEmptyInputAndBoundaries() {
        // (a) a gap between two rows in the same block: both paths must
        // return nil inside the gap.
        let gappedRows: [ReaderActiveBlockResolver.WordRow] = [
            (start: 0, end: 1, blockID: "g", wordIndex: 0),
            (start: 5, end: 6, blockID: "g", wordIndex: 1),
        ]
        let gappedIndex = ReaderActiveBlockResolver.WordIndex(rows: gappedRows)
        for t in stride(from: -0.5, through: 6.5, by: 0.1) {
            #expect(
                ReaderActiveBlockResolver.activeWord(in: gappedIndex, time: t, activeBlockID: "g")
                    == ReaderActiveBlockResolver.activeWord(
                        in: gappedRows, time: t, activeBlockID: "g"),
                "mismatch at t=\(t)")
        }
        #expect(
            ReaderActiveBlockResolver.activeWord(in: gappedIndex, time: 2.5, activeBlockID: "g")
                == nil)

        // (c) empty input.
        let emptyIndex = ReaderActiveBlockResolver.WordIndex(rows: [])
        #expect(
            ReaderActiveBlockResolver.activeWord(in: emptyIndex, time: 0, activeBlockID: "g") == nil
        )
        #expect(
            ReaderActiveBlockResolver.activeWord(in: emptyIndex, time: 0, activeBlockID: nil)
                == nil)

        // (d) exact boundary instants: time == start matches, time == end does not.
        let boundaryRows: [ReaderActiveBlockResolver.WordRow] = [
            (start: 2, end: 4, blockID: "h", wordIndex: 0)
        ]
        let boundaryIndex = ReaderActiveBlockResolver.WordIndex(rows: boundaryRows)
        #expect(
            ReaderActiveBlockResolver.activeWord(in: boundaryIndex, time: 2, activeBlockID: "h")
                == 0)
        #expect(
            ReaderActiveBlockResolver.activeWord(in: boundaryIndex, time: 4, activeBlockID: "h")
                == nil)
        #expect(
            ReaderActiveBlockResolver.activeWord(in: boundaryRows, time: 2, activeBlockID: "h")
                == ReaderActiveBlockResolver.activeWord(
                    in: boundaryIndex, time: 2, activeBlockID: "h"))
        #expect(
            ReaderActiveBlockResolver.activeWord(in: boundaryRows, time: 4, activeBlockID: "h")
                == ReaderActiveBlockResolver.activeWord(
                    in: boundaryIndex, time: 4, activeBlockID: "h"))
    }
}
