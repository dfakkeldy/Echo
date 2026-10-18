// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceSearchTests {
    @Test func searchReturnsBookLibraryItems() async throws {
        let fixture = AudiobookshelfServiceSearchFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/search",
            json: """
                {"book":[
                  {"libraryItem":{"id":"it1","libraryId":"lib1","media":{"metadata":{"title":"The Wakeful Body","author":"X"}}}},
                  {"libraryItem":{"id":"it2","libraryId":"lib1","media":{"metadata":{"title":"When the Body Says No","author":"Y"}}}}
                ],"authors":[],"genres":[],"narrators":[],"series":[],"tags":[]}
                """)
        let results = try await fixture.service.search(libraryID: "lib1", query: "body")
        #expect(results.items.map(\.id) == ["it1", "it2"])
        #expect(results.items.first?.title == "The Wakeful Body")
        #expect(!results.isLimited)
    }

    @Test func searchDecodesExpandedMetadataArraysFromCurrentABSResponses() async throws {
        let fixture = AudiobookshelfServiceSearchFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/search",
            json: """
                {"book":[
                  {"libraryItem":{"id":"it1","libraryId":"lib1","media":{"duration":43200,
                   "tags":["Relationships"],
                   "metadata":{"title":"High Conflict",
                    "authors":[{"id":"aut1","name":"Amanda Ripley"}],
                    "narrators":["Amanda Ripley"],
                    "series":[{"id":"ser1","name":"Conflict Studies","sequence":"1"}],
                    "genres":["Psychology"],
                    "publishedYear":"2021"}}},
                   "matchKey":"title","matchText":"High Conflict"}
                ],"tags":[],"authors":[],"series":[]}
                """)

        let results = try await fixture.service.search(libraryID: "lib1", query: "High Conflict")

        #expect(results.items.map(\.id) == ["it1"])
        #expect(results.items.first?.title == "High Conflict")
        #expect(results.items.first?.author == "Amanda Ripley")
        #expect(results.items.first?.media?.metadata?.narrator == "Amanda Ripley")
        #expect(results.items.first?.media?.metadata?.series == "Conflict Studies")
        #expect(results.items.first?.topics == ["Conflict Studies", "Psychology", "Relationships"])
    }

    @Test func searchFallsBackToLibraryItemsForAuthorOnlyResults() async throws {
        let fixture = AudiobookshelfServiceSearchFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/search",
            json: """
                {"book":[],"podcast":[],"authors":[{"id":"aut1","name":"Daniel Kahneman"}],
                 "genres":[],"narrators":[],"series":[],"tags":[]}
                """)
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/items",
            queryItems: ["page": "0", "limit": "25"],
            json: """
                {"total":2,"limit":25,"page":0,"results":[
                  {"id":"it1","libraryId":"lib1","media":{"metadata":{"title":"Thinking, Fast and Slow",
                   "authors":[{"id":"aut1","name":"Daniel Kahneman"}]}}},
                  {"id":"it2","libraryId":"lib1","media":{"metadata":{"title":"High Conflict",
                   "authors":[{"id":"aut2","name":"Amanda Ripley"}]}}}
                ]}
                """)

        let results = try await fixture.service.search(libraryID: "lib1", query: "Kahneman")

        #expect(results.items.map(\.id) == ["it1"])
        #expect(fixture.requests.contains { $0.url?.path.hasSuffix("/items") == true })
    }

    @Test func searchUnionsSeriesBooksWithDirectAndAuthorResultsUsingStableIDs() async throws {
        let fixture = AudiobookshelfServiceSearchFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/search",
            json: """
                {"book":[
                  {"libraryItem":{"id":"direct","libraryId":"lib1","media":{"metadata":{"title":"Direct"}}}},
                  {"libraryItem":{"id":"duplicate","libraryId":"lib1","media":{"metadata":{"title":"Direct Copy"}}}}
                ],"podcast":[],
                 "series":[{"series":{"id":"ser1","name":"Earthsea"},"books":[
                   {"id":"duplicate","libraryId":"lib1","media":{"metadata":{"title":"Series Copy"}}},
                   {"id":"series-only","libraryId":"lib1","media":{"metadata":{"title":"The Farthest Shore"}}}
                 ]}],
                 "authors":[{"id":"aut1","name":"Ursula K. Le Guin"}],
                 "genres":[],"narrators":[],"tags":[]}
                """)
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/items",
            queryItems: ["page": "0", "limit": "25"],
            json: """
                {"total":2,"limit":25,"page":0,"results":[
                  {"id":"author-only","libraryId":"lib1","media":{"metadata":{"title":"Lavinia","author":"Ursula K. Le Guin"}}},
                  {"id":"unrelated","libraryId":"lib1","media":{"metadata":{"title":"Other","author":"Someone Else"}}}
                ]}
                """)

        let results = try await fixture.service.search(libraryID: "lib1", query: "Earthsea")

        #expect(results.items.map(\.id) == ["direct", "duplicate", "series-only", "author-only"])
        #expect(results.items[1].title == "Direct Copy")
    }

    @Test func searchReportsCategoryLimitEvenWhenSeriesBooksDeduplicateBelowIt() async throws {
        let fixture = AudiobookshelfServiceSearchFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/search",
            json: """
                {"book":[{"libraryItem":{"id":"same","libraryId":"lib1"}}],
                 "podcast":[],"authors":[],
                 "series":[
                   {"series":{"id":"s1","name":"Saga One"},"books":[{"id":"same","libraryId":"lib1"}]},
                   {"series":{"id":"s2","name":"Saga Two"},"books":[{"id":"same","libraryId":"lib1"}]}
                 ]}
                """)

        let results = try await fixture.service.search(libraryID: "lib1", query: "Saga", limit: 2)

        #expect(results.items.map(\.id) == ["same"])
        #expect(results.isLimited)
    }

    @Test func emptyBookArrayReturnsEmpty() async throws {
        let fixture = AudiobookshelfServiceSearchFixture()
        URLProtocolStub.stub(
            scope: fixture.scope,
            pathSuffix: "/search",
            json: """
                {"book":[],"authors":[],"genres":[],"narrators":[],"series":[],"tags":[]}
                """)
        let results = try await fixture.service.search(libraryID: "lib1", query: "zzz")
        #expect(results.items.isEmpty)
        #expect(!results.isLimited)
    }
}

/// Per-test stub isolation: suites and the tests inside them run concurrently in
/// one process, so a shared stub scope lets one test's `reset()` erase another's
/// recorded requests. A unique scope per fixture keeps each test's traffic its own.
@MainActor
private final class AudiobookshelfServiceSearchFixture {
    let scope: String
    let service: AudiobookshelfService
    private let tokenStore: ABSTokenStore

    var requests: [URLRequest] { URLProtocolStub.requests(scope: scope) }

    init() {
        scope = "abs-search-service-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        tokenStore = ABSTokenStore(serverID: "search-\(UUID().uuidString)")
        tokenStore.accessToken = "acc"
        service = AudiobookshelfService(
            baseURL: URL(string: "http://h:13378")!,
            tokens: tokenStore, session: URLProtocolStub.makeSession(scope: scope))
    }

    isolated deinit {
        URLProtocolStub.finish(scope: scope)
    }
}
