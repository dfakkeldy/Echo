// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceLibraryTests {
    private func makeService() -> AudiobookshelfService {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "lib-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        return AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
    }

    @Test func fetchLibrariesDecodes() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/api/libraries",
            json: """
                {"libraries":[{"id":"lib1","name":"Audiobooks"},{"id":"lib2","name":"Podcasts"}]}
                """)
        let libs = try await service.libraries()
        #expect(libs.map(\.id) == ["lib1", "lib2"])
        #expect(libs.first?.name == "Audiobooks")
    }

    @Test func fetchItemsDecodesTitleAuthorDuration() async throws {
        let service = makeService()
        // Path suffix "/items" matches /api/libraries/lib1/items.
        URLProtocolStub.stub(
            pathSuffix: "/items",
            json: """
                {"total":1,"page":0,"results":[
                  {"id":"it1","libraryId":"lib1","media":{"duration":3600,"tags":["studied"],
                   "metadata":{"title":"Thinking Fast","author":"Kahneman"}}}
                ]}
                """)
        let page = try await service.items(
            libraryID: "lib1", query: ABSLibraryItemsQuery(sort: .title))
        #expect(page.results.first?.title == "Thinking Fast")
        #expect(page.results.first?.author == "Kahneman")
        #expect(page.results.first?.duration == 3600)
    }

    @Test func fetchLibraryFilterDataDecodesAllBrowseGroups() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/api/libraries/lib1",
            queryItems: ["include": "filterdata"],
            json: """
                {"filterdata":{
                  "authors":[{"id":"aut_1","name":"Author One"}],
                  "series":[{"id":"ser_1","name":"Series One"}],
                  "genres":["History"],
                  "tags":["Studied"]
                }}
                """)

        let filterData = try await service.libraryFilterData(libraryID: "lib1")

        #expect(filterData.authors == [
            ABSFilterOption(group: .authors, value: "aut_1", label: "Author One")
        ])
        #expect(filterData.series == [
            ABSFilterOption(group: .series, value: "ser_1", label: "Series One")
        ])
        #expect(filterData.genres == [
            ABSFilterOption(group: .genres, value: "History", label: "History")
        ])
        #expect(filterData.tags == [
            ABSFilterOption(group: .tags, value: "Studied", label: "Studied")
        ])
    }

    @Test func fetchItemsDecodesCurrentABSFilePayloadShapesAndMissingCoverPath() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/items",
            json: """
                {"total":1,"page":0,"results":[
                  {"id":"it1","libraryId":"lib1","media":{
                    "duration":0,
                    "audioFiles":[{"ino":"a1","mimeType":"audio/mp4","duration":120}],
                    "files":[{"ino":"f1","mimeType":"application/epub+zip","relPath":"book.epub"}],
                    "ebookFile":{"ino":"e1","mimeType":"application/epub+zip","relPath":"book.epub"},
                    "pdfFile":{"ino":"p1","mimeType":"application/pdf","relPath":"book.pdf"},
                    "metadata":{"title":"Mixed Media"}}}
                ]}
                """)

        let item = try #require(
            try await service.items(
                libraryID: "lib1", query: ABSLibraryItemsQuery(sort: .title)
            ).results.first)

        #expect(item.title == "Mixed Media")
        #expect(item.coverPath == nil)
        #expect(item.media?.audioFiles?.first?.mimeType == "audio/mp4")
        #expect(item.media?.files?.first?.relPath == "book.epub")
        #expect(item.media?.ebookFile?.relPath == "book.epub")
        #expect(item.media?.pdfFile?.relPath == "book.pdf")
        #expect(item.hasAudioContent)
    }

    @Test func fetchAllItemsRequestsPagesUntilTotalIsReached() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "0", "limit": "2"],
            json: """
                {"total":3,"limit":2,"page":0,"results":[
                  {"id":"itA","libraryId":"lib1","media":{"metadata":{"title":"A Book"}}},
                  {"id":"itB","libraryId":"lib1","media":{"metadata":{"title":"B Book"}}}
                ]}
                """)
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "1", "limit": "2"],
            json: """
                {"total":3,"limit":2,"page":1,"results":[
                  {"id":"itC","libraryId":"lib1","media":{"metadata":{"title":"C Book"}}}
                ]}
                """)

        let items = try await service.allItems(
            libraryID: "lib1", query: ABSLibraryItemsQuery(limit: 2, sort: .title))
        let requestedPages = URLProtocolStub.requests.compactMap { request -> String? in
            guard request.url?.path.hasSuffix("/items") == true,
                let url = request.url,
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "page" })?.value
            else { return nil }
            return page
        }

        #expect(items.map(\.id) == ["itA", "itB", "itC"])
        #expect(requestedPages == ["0", "1"])
    }

    @Test func fetchAllItemsStopsAfterShortNonzeroStartPageWithoutNumPages() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "1", "limit": "2"],
            json: """
                {"total":3,"limit":2,"page":1,"results":[
                  {"id":"itC","libraryId":"lib1","media":{"metadata":{"title":"C Book"}}}
                ]}
                """)

        let items = try await service.allItems(
            libraryID: "lib1", query: ABSLibraryItemsQuery(page: 1, limit: 2, sort: .title))
        let requestedPages = URLProtocolStub.requests.compactMap { request -> String? in
            guard let url = request.url else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value
        }

        #expect(items.map(\.id) == ["itC"])
        #expect(requestedPages == ["1"])
    }

    @Test func fetchAllItemsStopsAfterFullNonzeroFinalPageUsingTotalOffset() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "1", "limit": "2"],
            json: """
                {"total":4,"limit":2,"page":1,"results":[
                  {"id":"itC","libraryId":"lib1","media":{"metadata":{"title":"C Book"}}},
                  {"id":"itD","libraryId":"lib1","media":{"metadata":{"title":"D Book"}}}
                ]}
                """)

        let items = try await service.allItems(
            libraryID: "lib1", query: ABSLibraryItemsQuery(page: 1, limit: 2, sort: .title))
        let requestedPages = requestedItemPages()

        #expect(items.map(\.id) == ["itC", "itD"])
        #expect(requestedPages == ["1"])
    }

    @Test func fetchAllItemsContinuesWhenServerCapsPageSize() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "0", "limit": "100"],
            json: """
                {"total":3,"limit":2,"page":0,"results":[
                  {"id":"itA","libraryId":"lib1","media":{"metadata":{"title":"A Book"}}},
                  {"id":"itB","libraryId":"lib1","media":{"metadata":{"title":"B Book"}}}
                ]}
                """)
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "1", "limit": "100"],
            json: """
                {"total":3,"limit":2,"page":1,"results":[
                  {"id":"itC","libraryId":"lib1","media":{"metadata":{"title":"C Book"}}}
                ]}
                """)

        let items = try await service.allItems(
            libraryID: "lib1", query: ABSLibraryItemsQuery(limit: 100, sort: .title))
        let requestedPages = requestedItemPages()

        #expect(items.map(\.id) == ["itA", "itB", "itC"])
        #expect(requestedPages == ["0", "1"])
    }

    @Test func pagedItemsEmitsPagesBeforeLaterPageFails() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "0", "limit": "2"],
            json: """
                {"total":3,"limit":2,"page":0,"results":[
                  {"id":"itA","libraryId":"lib1","media":{"metadata":{"title":"A Book"}}},
                  {"id":"itB","libraryId":"lib1","media":{"metadata":{"title":"B Book"}}}
                ]}
                """)
        URLProtocolStub.stub(
            pathSuffix: "/items",
            queryItems: ["page": "1", "limit": "2"],
            status: 500,
            json: #"{"error":"boom"}"#)

        var emittedIDs: [String] = []

        do {
            _ = try await service.pagedItems(
                libraryID: "lib1", query: ABSLibraryItemsQuery(limit: 2, sort: .title)
            ) { pageItems in
                emittedIDs.append(contentsOf: pageItems.map(\.id))
            }
            Issue.record("Expected the second page to fail")
        } catch ABSError.http(let status, _) {
            #expect(status == 500)
        }

        #expect(emittedIDs == ["itA", "itB"])
    }

    @Test func fetchItemDetailDecodes() async throws {
        let service = makeService()
        URLProtocolStub.stub(
            pathSuffix: "/api/items/it1",
            json: """
                {"id":"it1","libraryId":"lib1","media":{"duration":3600,"numTracks":1,
                 "tracks":[{"index":0,"duration":3600,"title":"Chapter 1"}],
                 "metadata":{"title":"Thinking Fast","author":"Kahneman"}}}
                """)
        let item = try await service.item(id: "it1")
        #expect(item.title == "Thinking Fast")
        #expect(item.media?.tracks?.first?.title == "Chapter 1")
    }

    @Test func coverImageDataUsesAuthorizationHeaderWithoutTokenQuery() async throws {
        let service = makeService()  // tokens.accessToken == "acc"
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        URLProtocolStub.stub(
            pathSuffix: "/api/items/it1/cover", status: 200, data: payload,
            headers: ["Content-Type": "image/png"])

        let data = try await service.coverImageData(itemID: "it1")
        let request = try #require(URLProtocolStub.requests.last)
        let queryItems = URLComponents(
            url: try #require(request.url), resolvingAgainstBaseURL: false
        )?.queryItems ?? []

        #expect(data == payload)
        #expect(request.url?.path == "/api/items/it1/cover")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acc")
        #expect(!queryItems.contains { $0.name == "token" })
    }

    private func requestedItemPages() -> [String] {
        URLProtocolStub.requests.compactMap { request -> String? in
            guard request.url?.path.hasSuffix("/items") == true,
                let url = request.url
            else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value
        }
    }
}
