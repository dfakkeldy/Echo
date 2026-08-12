// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ABSBrowseOrderingTests {
    @Test func unionsInsideCategoryAndIntersectsCategories() {
        let groups: [ABSFilterGroup: [[String]]] = [
            .authors: [["a", "b"], ["b", "c"]],
            .genres: [["b", "d"]],
        ]

        #expect(ABSBrowseResultResolver.combinedIDs(filteredBy: groups) == ["b"])
    }

    @Test func seriesUsesNameNumericSequenceThenTitle() throws {
        let sorted = ABSBrowseResultResolver.sorted(
            try ABSBrowseOrderingFixture.items(), by: .series)

        #expect(sorted.map(\.id) == ["saga-2", "saga-10", "saga-missing", "standalone"])
    }
}

private enum ABSBrowseOrderingFixture {
    static func items() throws -> [ABSLibraryItem] {
        let data = Data(Self.json.utf8)
        return try JSONDecoder().decode([ABSLibraryItem].self, from: data)
    }

    private static let json = """
        [
          {"id":"saga-10","libraryId":"l1","media":{"metadata":{"title":"Ten","series":[{"name":"Saga","sequence":"10"}]}}},
          {"id":"standalone","libraryId":"l1","media":{"metadata":{"title":"Alone"}}},
          {"id":"saga-2","libraryId":"l1","media":{"metadata":{"title":"Two","series":[{"name":"Saga","sequence":"2"}]}}},
          {"id":"saga-missing","libraryId":"l1","media":{"metadata":{"title":"Unknown","series":[{"name":"Saga"}]}}}
        ]
        """
}
