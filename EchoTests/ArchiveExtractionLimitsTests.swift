// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Guards archive extraction against decompression bombs: a single huge entry
/// or many entries that together blow the cumulative budget must be rejected
/// before any bytes are written. See CODE_AUDIT.md §6.1.
struct ArchiveExtractionLimitsTests {

    @Test func acceptsEntriesWithinBudget() throws {
        var total: UInt64 = 0
        total = try ArchiveExtractionLimits.checkedTotal(addingEntryOfSize: 10 * 1024 * 1024, to: total)
        total = try ArchiveExtractionLimits.checkedTotal(addingEntryOfSize: 20 * 1024 * 1024, to: total)
        #expect(total == 30 * 1024 * 1024)
    }

    @Test func acceptsEntryExactlyAtPerEntryLimit() throws {
        let total = try ArchiveExtractionLimits.checkedTotal(
            addingEntryOfSize: ArchiveExtractionLimits.maxEntryBytes, to: 0
        )
        #expect(total == ArchiveExtractionLimits.maxEntryBytes)
    }

    @Test func rejectsSingleOversizedEntry() {
        #expect(throws: ArchiveExtractionLimits.LimitError.self) {
            _ = try ArchiveExtractionLimits.checkedTotal(
                addingEntryOfSize: ArchiveExtractionLimits.maxEntryBytes + 1, to: 0
            )
        }
    }

    @Test func rejectsWhenCumulativeBudgetExceeded() {
        // Each entry is under the per-entry cap, but together they exceed the total.
        #expect(throws: ArchiveExtractionLimits.LimitError.self) {
            var total: UInt64 = 0
            for _ in 0..<6 {   // 6 × 90 MB = 540 MB > 512 MB total cap
                total = try ArchiveExtractionLimits.checkedTotal(
                    addingEntryOfSize: 90 * 1024 * 1024, to: total
                )
            }
        }
    }
}
