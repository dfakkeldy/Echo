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

    @Test func seriesUsesNumericSequenceForSingleObjectMetadataShape() throws {
        let items = try ABSBrowseOrderingFixture.items(
            """
            [
              {"id":"ten","libraryId":"l1","media":{"metadata":{"title":"Ten","series":{"name":"Saga","sequence":"10"}}}},
              {"id":"two","libraryId":"l1","media":{"metadata":{"title":"Two","series":{"name":"Saga","sequence":"2"}}}}
            ]
            """)

        #expect(ABSBrowseResultResolver.sorted(items, by: .series).map(\.id) == ["two", "ten"])
    }

    @Test func retainsFirstDuplicateBeforeSorting() throws {
        let items = try ABSBrowseOrderingFixture.items(
            """
            [
              {"id":"duplicate","libraryId":"l1","media":{"metadata":{"title":"Zebra"}}},
              {"id":"middle","libraryId":"l1","media":{"metadata":{"title":"Middle"}}},
              {"id":"duplicate","libraryId":"l1","media":{"metadata":{"title":"Apple"}}}
            ]
            """)

        #expect(ABSBrowseResultResolver.sorted(items, by: .title).map(\.id) == ["middle", "duplicate"])
    }

    @Test func seriesPlacesUnparseableSequencesAfterNumericSequences() throws {
        let items = try ABSBrowseOrderingFixture.items(
            """
            [
              {"id":"missing","libraryId":"l1","media":{"metadata":{"title":"Bravo","series":[{"name":"Saga"}]}}},
              {"id":"invalid","libraryId":"l1","media":{"metadata":{"title":"Alpha","series":[{"name":"Saga","sequence":"side-story"}]}}},
              {"id":"numeric","libraryId":"l1","media":{"metadata":{"title":"Zulu","series":[{"name":"Saga","sequence":"1"}]}}}
            ]
            """)

        #expect(ABSBrowseResultResolver.sorted(items, by: .series).map(\.id) == ["numeric", "invalid", "missing"])
    }

    @Test func seriesUsesTitleThenIDAsTieBreakers() throws {
        let items = try ABSBrowseOrderingFixture.items(
            """
            [
              {"id":"tie-b","libraryId":"l1","media":{"metadata":{"title":"Same","series":[{"name":"Saga","sequence":"1"}]}}},
              {"id":"later-title","libraryId":"l1","media":{"metadata":{"title":"Zulu","series":[{"name":"Saga","sequence":"1"}]}}},
              {"id":"first-title","libraryId":"l1","media":{"metadata":{"title":"Alpha","series":[{"name":"Saga","sequence":"1"}]}}},
              {"id":"tie-a","libraryId":"l1","media":{"metadata":{"title":"Same","series":[{"name":"Saga","sequence":"1"}]}}}
            ]
            """)

        #expect(
            ABSBrowseResultResolver.sorted(items, by: .series).map(\.id)
                == ["first-title", "tie-a", "tie-b", "later-title"])
    }

    @Test func appliesLocalFallbacksForNonSeriesSorts() throws {
        let items = try ABSBrowseOrderingFixture.items(
            """
            [
              {"id":"old","libraryId":"l1","addedAt":1,"media":{"metadata":{"title":"Zulu","author":"Zed","publishedYear":"2001"}}},
              {"id":"new","libraryId":"l1","addedAt":3,"media":{"metadata":{"title":"Alpha","author":"Amy","publishedYear":"2020"}}},
              {"id":"middle","libraryId":"l1","addedAt":2,"media":{"metadata":{"title":"Middle","author":"Moe","publishedYear":"2010"}}}
            ]
            """)

        #expect(ABSBrowseResultResolver.sorted(items, by: .newestAdded).map(\.id) == ["new", "middle", "old"])
        #expect(ABSBrowseResultResolver.sorted(items, by: .title).map(\.id) == ["new", "middle", "old"])
        #expect(ABSBrowseResultResolver.sorted(items, by: .author).map(\.id) == ["new", "middle", "old"])
        #expect(ABSBrowseResultResolver.sorted(items, by: .publicationYear).map(\.id) == ["new", "middle", "old"])
    }
}

private enum ABSBrowseOrderingFixture {
    static func items() throws -> [ABSLibraryItem] {
        try items(Self.json)
    }

    static func items(_ json: String) throws -> [ABSLibraryItem] {
        let data = Data(json.utf8)
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
