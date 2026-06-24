// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceSearchTests {
    private func makeService() -> AudiobookshelfService {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "search-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        return AudiobookshelfService(
            baseURL: URL(string: "http://h:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
    }

    @Test func searchReturnsBookLibraryItems() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/search",
            json: """
                {"book":[
                  {"libraryItem":{"id":"it1","libraryId":"lib1","media":{"metadata":{"title":"The Wakeful Body","author":"X"}}}},
                  {"libraryItem":{"id":"it2","libraryId":"lib1","media":{"metadata":{"title":"When the Body Says No","author":"Y"}}}}
                ],"authors":[],"genres":[],"narrators":[],"series":[],"tags":[]}
                """)
        let results = try await service.search(libraryID: "lib1", query: "body")
        #expect(results.map(\.id) == ["it1", "it2"])
        #expect(results.first?.title == "The Wakeful Body")
    }

    @Test func searchDecodesExpandedMetadataArraysFromCurrentABSResponses() async throws {
        let service = makeService()
        URLProtocolStub.stub(
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

        let results = try await service.search(libraryID: "lib1", query: "High Conflict")

        #expect(results.map(\.id) == ["it1"])
        #expect(results.first?.title == "High Conflict")
        #expect(results.first?.author == "Amanda Ripley")
        #expect(results.first?.media?.metadata?.narrator == "Amanda Ripley")
        #expect(results.first?.media?.metadata?.series == "Conflict Studies")
        #expect(results.first?.topics == ["Conflict Studies", "Psychology", "Relationships"])
    }

    @Test func emptyBookArrayReturnsEmpty() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/search",
            json: """
                {"book":[],"authors":[],"genres":[],"narrators":[],"series":[],"tags":[]}
                """)
        let results = try await service.search(libraryID: "lib1", query: "zzz")
        #expect(results.isEmpty)
    }
}
