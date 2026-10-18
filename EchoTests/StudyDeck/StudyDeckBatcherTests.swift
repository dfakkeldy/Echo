// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class StudyDeckBatcherTests: XCTestCase {
    private let batcher = StudyDeckBatcher()

    // MARK: - Helpers

    private func makeSource(id: String = UUID().uuidString, spineIndex: Int) -> StudyDeckSource {
        StudyDeckSource(
            id: id,
            sourceBlockID: "block-\(id)",
            audiobookID: "book-1",
            blockKind: "paragraph",
            text: "Sample text for block \(id).",
            chapterIndex: spineIndex,
            sequenceIndex: 0,
            spineIndex: spineIndex,
            blockIndex: 0
        )
    }

    // MARK: - Tests

    func test_empty_sources_returns_empty() {
        let result = batcher.batches(from: [], maxPerBatch: 12)
        XCTAssertEqual(result, [])
    }

    func test_single_spine_splits_at_maxPerBatch() {
        // 30 sources all in spine 0, maxPerBatch 12 → [12, 12, 6]
        let sources = (0..<30).map { makeSource(id: "\($0)", spineIndex: 0) }
        let result = batcher.batches(from: sources, maxPerBatch: 12)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].count, 12)
        XCTAssertEqual(result[1].count, 12)
        XCTAssertEqual(result[2].count, 6)
    }

    func test_spine_change_forces_split_even_under_cap() {
        // 3 in spine 0 then 2 in spine 1, maxPerBatch 12 → 2 batches
        let spineZero = (0..<3).map { makeSource(id: "s0-\($0)", spineIndex: 0) }
        let spineOne = (0..<2).map { makeSource(id: "s1-\($0)", spineIndex: 1) }
        let sources = spineZero + spineOne

        let result = batcher.batches(from: sources, maxPerBatch: 12)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].count, 3)
        XCTAssertEqual(result[1].count, 2)
        // Verify contents: each batch should contain exactly the sources we created.
        // Comparing full Equatable values avoids accessing main-actor-inferred properties
        // directly from a nonisolated context under -default-isolation MainActor.
        XCTAssertEqual(result[0], spineZero)
        XCTAssertEqual(result[1], spineOne)
    }
}
