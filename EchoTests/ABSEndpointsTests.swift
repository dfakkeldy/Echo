// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ABSEndpointsTests {
    @Test func normalizesBareHostPortToHTTP() {
        let url = ABSEndpoints.normalizedBaseURL(from: "100.95.69.48:13378/audiobookshelf/")
        #expect(url?.absoluteString == "http://100.95.69.48:13378/audiobookshelf")
    }
    @Test func preservesSubpathOnEndpoints() {
        let base = ABSEndpoints.normalizedBaseURL(from: "http://host:13378/audiobookshelf")!
        let e = ABSEndpoints(baseURL: base)
        #expect(e.login().absoluteString == "http://host:13378/audiobookshelf/login")
        #expect(e.libraries().absoluteString == "http://host:13378/audiobookshelf/api/libraries")
    }
    @Test func itemsURLCarriesPagingQuery() {
        let e = ABSEndpoints(baseURL: URL(string: "http://host/abs")!)
        let s = e.items(libraryID: "lib1", page: 2, limit: 25, filter: nil).absoluteString
        #expect(s.contains("/abs/api/libraries/lib1/items"))
        #expect(s.contains("page=2"))
        #expect(s.contains("limit=25"))
    }
    @Test func rejectsUnparseableInput() {
        #expect(ABSEndpoints.normalizedBaseURL(from: "   ") == nil)
    }
}
