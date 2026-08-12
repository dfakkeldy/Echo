// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ABSEndpointsTests {
    @Test func normalizesBareHostPortToHTTPS() {
        let url = ABSEndpoints.normalizedBaseURL(from: "100.95.69.48:13378/audiobookshelf/")
        #expect(url?.absoluteString == "https://100.95.69.48:13378/audiobookshelf")
        #expect(url.map(ABSEndpoints.requiresPlainHTTPConfirmation) == false)
    }

    @Test func preservesExplicitPlainHTTPAndRequiresConfirmation() {
        let url = ABSEndpoints.normalizedBaseURL(from: "http://host:13378/audiobookshelf/")!
        #expect(url.absoluteString == "http://host:13378/audiobookshelf")
        #expect(ABSEndpoints.requiresPlainHTTPConfirmation(url))
    }

    @Test func preservesSubpathOnEndpoints() {
        let base = ABSEndpoints.normalizedBaseURL(from: "https://host:13378/audiobookshelf")!
        let e = ABSEndpoints(baseURL: base)
        #expect(e.login().absoluteString == "https://host:13378/audiobookshelf/login")
        #expect(e.libraries().absoluteString == "https://host:13378/audiobookshelf/api/libraries")
    }

    @Test func itemsURLCarriesPagingQuery() {
        let e = ABSEndpoints(baseURL: URL(string: "https://host/abs")!)
        let query = ABSLibraryItemsQuery(
            page: 2, limit: 25, sort: .newestAdded,
            filter: ABSFilterOption(group: .tags, value: "studied", label: "Studied"))
        let s = e.items(libraryID: "lib1", query: query).absoluteString
        #expect(s.contains("/abs/api/libraries/lib1/items"))
        #expect(s.contains("page=2"))
        #expect(s.contains("limit=25"))
        #expect(s.contains("sort=addedAt"))
        #expect(s.contains("desc=1"))
        #expect(s.contains("filter=tags.c3R1ZGllZA%3D%3D"))
    }

    @Test func rejectsUnparseableInput() {
        #expect(ABSEndpoints.normalizedBaseURL(from: "   ") == nil)
    }

    @Test func serverRecordDerivesPlainHTTPStateFromPersistedURL() {
        let httpServer = ABSServerRecord(
            id: "http", baseURL: "http://host:13378", username: "me",
            defaultLibraryId: nil, addedAt: "2026-06-26T00:00:00Z")
        let httpsServer = ABSServerRecord(
            id: "https", baseURL: "https://host:13378", username: "me",
            defaultLibraryId: nil, addedAt: "2026-06-26T00:00:00Z")

        #expect(httpServer.isPlainHTTP)
        #expect(!httpsServer.isPlainHTTP)
    }
}
