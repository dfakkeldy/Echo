// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct ABSBrowseQueryTests {
    @Test func newestUsesAddedAtDescending() {
        let query = ABSLibraryItemsQuery(sort: .newestAdded)

        #expect(query.sortField == "addedAt")
        #expect(query.descending)
    }

    @Test func authorFilterUsesGroupDotBase64() {
        let option = ABSFilterOption(
            group: .authors,
            value: "aut_z3leimgybl7uf3y4ab",
            label: "Terry Goodkind")

        #expect(option.encodedFilter == "authors.YXV0X3ozbGVpbWd5Ymw3dWYzeTRhYg==")
    }

    @Test func decodesAddedAtAndSeriesSequence() throws {
        let data = Data(
            #"{"id":"i1","libraryId":"l1","addedAt":1650621073750,"media":{"metadata":{"title":"Book","series":[{"name":"Saga","sequence":"2"}]}}}"#
                .utf8)

        let item = try JSONDecoder().decode(ABSLibraryItem.self, from: data)

        #expect(item.addedAt == 1_650_621_073_750)
        #expect(item.seriesName == "Saga")
        #expect(item.seriesSequence == "2")
    }

    @Test func decodesSingleObjectSeriesNameAndSequence() throws {
        let data = Data(
            #"{"id":"i1","libraryId":"l1","media":{"metadata":{"title":"Book","series":{"id":"s1","name":"Saga","sequence":"10"}}}}"#
                .utf8)

        let item = try JSONDecoder().decode(ABSLibraryItem.self, from: data)

        #expect(item.seriesName == "Saga")
        #expect(item.seriesSequence == "10")
    }
}
