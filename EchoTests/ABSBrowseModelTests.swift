// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct ABSBrowseModelTests {
    @Test func defaultsToNewestDescending() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibrariesAndEmptyItems()

        await fixture.model.load()

        let request = try #require(fixture.requests.last)
        let query = URLComponents(
            url: try #require(request.url), resolvingAgainstBaseURL: false)
        #expect(query?.queryItems?.contains(.init(name: "sort", value: "addedAt")) == true)
        #expect(query?.queryItems?.contains(.init(name: "desc", value: "1")) == true)
    }

    @Test func changingSortPersistsItsRawValue() async throws {
        let fixture = try ABSBrowseModelFixture()

        let task = fixture.model.setSort(.author)

        #expect(fixture.persistedSortRawValue == "author")
        #expect(fixture.makeReloadedModel().sort == .author)
        await task.value
    }

    @Test func notAddedRemovesUsableBook() async throws {
        let fixture = try ABSBrowseModelFixture(importedRemoteID: "i1")
        fixture.stubLibraryItems(ids: ["i1", "i2"])

        await fixture.model.load()
        await fixture.model.setNotAddedOnly(true).value

        #expect(fixture.model.displayedItems.map(\.id) == ["i2"])
        #expect(fixture.model.totalCount == 1)
    }

    @Test func notAddedLoadsCompleteQueryBeforePublishingExactCount() async throws {
        let fixture = try ABSBrowseModelFixture()
        try fixture.insertUsableProvenance(remoteID: "i1", folderName: "first")
        try fixture.insertUsableProvenance(remoteID: "i2", folderName: "second")
        fixture.stubPagedItems(page: 0, ids: ["i1"], total: 3)
        fixture.stubPagedItems(page: 1, ids: ["i2"], total: 3)
        fixture.stubPagedItems(page: 2, ids: ["i3"], total: 3)
        await fixture.model.load()

        await fixture.model.setNotAddedOnly(true).value

        #expect(fixture.model.displayedItems.map(\.id) == ["i3"])
        #expect(fixture.model.totalCount == 1)
        #expect(fixture.requestedItemPages == ["0", "0", "1", "2"])
    }

    @Test func multipleFiltersFanOutCompleteQueriesAndCombineIDs() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraryItems(ids: ["i1", "i2", "i3", "i4"])
        fixture.stubFilterData()
        fixture.stubFilteredItems(option: ABSBrowseModelFixture.authorOne, ids: ["i1", "i2"])
        fixture.stubFilteredItems(option: ABSBrowseModelFixture.authorTwo, ids: ["i3"])
        fixture.stubFilteredItems(
            option: ABSBrowseModelFixture.history, ids: ["i2", "i3", "i4"])
        await fixture.model.load()

        fixture.model.toggleFilter(ABSBrowseModelFixture.authorOne)
        fixture.model.toggleFilter(ABSBrowseModelFixture.authorTwo)
        fixture.model.toggleFilter(ABSBrowseModelFixture.history)
        try await waitUntilLoaded(fixture.model)

        #expect(fixture.model.displayedItems.map(\.id) == ["i3", "i2"])
        #expect(fixture.model.totalCount == 2)
        let filters = fixture.requests.compactMap { request -> String? in
            guard let url = request.url else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "filter" })?.value
        }
        #expect(
            Set(filters).isSuperset(of: [
                ABSBrowseModelFixture.authorOne.encodedFilter,
                ABSBrowseModelFixture.authorTwo.encodedFilter,
                ABSBrowseModelFixture.history.encodedFilter,
            ]))
    }

    @Test func staleSortResponseCannotOverwriteNewerResults() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraryItems(ids: ["initial"])
        await fixture.model.load()
        fixture.stub(
            pathSuffix: "/items", queryItems: ["sort": "media.metadata.title"],
            json: fixture.itemsJSON(ids: ["stale"]), suspended: true)
        fixture.stub(
            pathSuffix: "/items", queryItems: ["sort": "media.metadata.authorName"],
            json: fixture.itemsJSON(ids: ["current"]))

        let staleTask = fixture.model.setSort(.title)
        try await waitUntilRequest(in: fixture, sort: "media.metadata.title")
        let currentTask = fixture.model.setSort(.author)
        await currentTask.value
        #expect(fixture.model.displayedItems.map(\.id) == ["current"])

        fixture.resume(pathSuffix: "/items", queryItems: ["sort": "media.metadata.title"])
        await staleTask.value
        #expect(fixture.model.displayedItems.map(\.id) == ["current"])
    }

    @Test func nextPageAppendsWithoutClearingPriorRows() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubPagedItems(page: 0, ids: ["i1"], total: 2)
        fixture.stubPagedItems(page: 1, ids: ["i2"], total: 2, suspended: true)
        await fixture.model.load()

        let nextPage = Task { await fixture.model.loadNextPageIfNeeded() }
        try await waitUntilRequest(in: fixture, page: "1")
        #expect(fixture.model.displayedItems.map(\.id) == ["i1"])
        #expect(fixture.model.isLoadingNextPage)

        fixture.resume(pathSuffix: "/items", queryItems: ["page": "1"])
        await nextPage.value
        #expect(fixture.model.displayedItems.map(\.id) == ["i1", "i2"])
        #expect(fixture.model.totalCount == 2)
    }

    @Test func refreshPreservesQuerySortAndFilters() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraryItems(ids: ["i1"])
        fixture.stubFilterData()
        fixture.stubFilteredItems(option: ABSBrowseModelFixture.history, ids: ["i1"])
        fixture.stubSearch(query: "needle", ids: ["i1"])
        await fixture.model.load()
        fixture.model.setSort(.author)
        fixture.model.toggleFilter(ABSBrowseModelFixture.history)
        fixture.model.setNotAddedOnly(true)
        fixture.model.setSearchQuery("needle")
        try await waitUntilLoaded(fixture.model)

        await fixture.model.refresh()

        #expect(fixture.model.searchQuery == "needle")
        #expect(fixture.model.sort == .author)
        #expect(fixture.model.selection.options == [ABSBrowseModelFixture.history])
        #expect(fixture.model.selection.notAddedOnly)
        #expect(fixture.model.displayedItems.map(\.id) == ["i1"])
    }

    @Test func newerSearchCancelsAndRejectsOlderSearch() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraryItems(ids: ["initial"])
        fixture.stubSearch(query: "old", ids: ["old"], suspended: true)
        fixture.stubSearch(query: "new", ids: ["new"])
        await fixture.model.load()

        let staleTask = fixture.model.setSearchQuery("old")
        try await waitUntilRequest(in: fixture, search: "old")
        let currentTask = fixture.model.setSearchQuery("new")
        await currentTask.value
        #expect(fixture.model.displayedItems.map(\.id) == ["new"])

        fixture.resume(pathSuffix: "/search", queryItems: ["q": "old"])
        await staleTask.value
        #expect(fixture.model.displayedItems.map(\.id) == ["new"])
    }

    @Test func callerCancellationCancelsOwnedRefreshAndPendingTransport() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibrariesAndEmptyItems()
        await fixture.model.load()
        fixture.stub(
            pathSuffix: "/api/libraries", queryItems: [:],
            json: #"{"libraries":[{"id":"l1","name":"Library"}]}"#,
            suspended: true)

        let priorRequestCount = fixture.requests.count
        let refresh = Task { await fixture.model.refresh() }
        try await waitUntilRequest(
            in: fixture, pathSuffix: "/api/libraries", afterRequestCount: priorRequestCount)
        refresh.cancel()
        await refresh.value

        #expect(fixture.pendingResponseCount == 0)
    }

    @Test func lifecycleCancelStopsOwnedRequestAndReturnsToIdle() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraryItems(ids: ["initial"])
        await fixture.model.load()
        fixture.stub(
            pathSuffix: "/items", queryItems: ["sort": "media.metadata.title"],
            json: fixture.itemsJSON(ids: ["late"]), suspended: true)

        let load = fixture.model.setSort(.title)
        try await waitUntilRequest(in: fixture, sort: "media.metadata.title")
        fixture.model.cancel()
        await load.value

        #expect(fixture.model.loadState == .idle)
        #expect(fixture.pendingResponseCount == 0)
    }

    @Test func lifecycleCancelReleasesModelAfterSuspendedNetworkingEnds() async throws {
        var fixture: ABSBrowseModelFixture? = try ABSBrowseModelFixture()
        fixture?.stubLibraryItems(ids: ["initial"])
        await fixture?.model.load()
        fixture?.stub(
            pathSuffix: "/items", queryItems: ["sort": "media.metadata.title"],
            json: fixture?.itemsJSON(ids: ["late"]) ?? "{}", suspended: true)
        weak var model = fixture?.model

        let load = try #require(fixture?.model.setSort(.title))
        try await waitUntilRequest(in: try #require(fixture), sort: "media.metadata.title")
        fixture?.model.cancel()
        await load.value
        fixture = nil

        #expect(model == nil)
    }

    @Test func libraryChangeClearsMetadataFiltersButKeepsNotAdded() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraries(ids: ["l1", "l2"])
        fixture.stubLibraryItems(ids: ["i1"], libraryID: "l1")
        fixture.stubLibraryItems(ids: ["i2"], libraryID: "l2")
        fixture.stubFilterData(libraryID: "l1")
        fixture.stubFilterData(libraryID: "l2")
        fixture.stubFilteredItems(
            option: ABSBrowseModelFixture.history, ids: ["i1"], libraryID: "l1")
        await fixture.model.load()
        fixture.model.toggleFilter(ABSBrowseModelFixture.history)
        fixture.model.setNotAddedOnly(true)
        try await waitUntilLoaded(fixture.model)

        fixture.model.selectLibrary("l2")
        try await waitUntilLoaded(fixture.model)

        #expect(fixture.model.selectedLibraryID == "l2")
        #expect(fixture.model.selection.options.isEmpty)
        #expect(fixture.model.selection.notAddedOnly)
        #expect(fixture.model.displayedItems.map(\.id) == ["i2"])
    }

    @Test func ordinaryPagePublishesServerResultTotal() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubPagedItems(page: 0, ids: ["i1"], total: 42)

        await fixture.model.load()

        #expect(fixture.model.totalCount == 42)
    }

    @Test func duplicateProvenanceUsesDeterministicBookWithoutTrap() async throws {
        let fixture = try ABSBrowseModelFixture()
        let later = try fixture.insertUsableProvenance(remoteID: "duplicate", folderName: "zeta")
        let earlier = try fixture.insertUsableProvenance(remoteID: "duplicate", folderName: "alpha")
        fixture.stubLibrariesAndEmptyItems()

        await fixture.model.load()

        #expect(fixture.model.addedBooksByRemoteID["duplicate"]?.folderURL == earlier)
        #expect(fixture.model.addedBooksByRemoteID["duplicate"]?.folderURL != later)
    }

    @Test func searchAtServerCapIsLabeledLimited() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibrariesAndEmptyItems()
        fixture.stubSearch(query: "many", ids: (0..<10_000).map { "i\($0)" })
        await fixture.model.load()

        fixture.model.setSearchQuery("many")
        try await waitUntilLoaded(fixture.model)

        #expect(fixture.model.totalCount == 10_000)
        #expect(fixture.model.searchResultsAreLimited)
        let request = try #require(
            fixture.requests.last(where: { $0.url?.path.hasSuffix("/search") == true }))
        let query = URLComponents(
            url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(.init(name: "limit", value: "10000")) == true)
    }

    @Test func emptyLibraryRefreshClearsLimitedSearchState() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibrariesAndEmptyItems()
        fixture.stubSearch(query: "many", ids: (0..<10_000).map { "i\($0)" })
        await fixture.model.load()
        await fixture.model.setSearchQuery("many").value
        #expect(fixture.model.searchResultsAreLimited)
        fixture.stubLibraries(ids: [])

        await fixture.model.refresh()

        #expect(!fixture.model.searchResultsAreLimited)
        #expect(fixture.model.totalCount == 0)
    }

    private func waitUntilLoaded(_ model: ABSBrowseModel) async throws {
        for _ in 0..<50_000 {
            if model.loadState == .loaded { return }
            await Task.yield()
        }
        throw TimeoutError()
    }

    private func waitUntilRequest(
        in fixture: ABSBrowseModelFixture,
        pathSuffix: String? = nil,
        page: String? = nil, sort: String? = nil, search: String? = nil,
        afterRequestCount: Int = 0
    ) async throws {
        for _ in 0..<50_000 {
            if fixture.requests.dropFirst(afterRequestCount).contains(where: { request in
                guard let url = request.url,
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                else { return false }
                let query = components.queryItems ?? []
                if let pathSuffix, !url.path.hasSuffix(pathSuffix) { return false }
                if let page, !query.contains(.init(name: "page", value: page)) { return false }
                if let sort, !query.contains(.init(name: "sort", value: sort)) { return false }
                if let search, !query.contains(.init(name: "q", value: search)) { return false }
                return true
            }) {
                return
            }
            await Task.yield()
        }
        throw TimeoutError()
    }

    private struct TimeoutError: Error {}
}

@Suite struct URLProtocolStubLifecycleTests {
    @Test func canceledSuspendedRequestIsRemovedAndScopeCanBeCleaned() async throws {
        let scope = "url-stub-lifecycle-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/suspended", json: "{}", suspended: true)
        let session = URLProtocolStub.makeSession(scope: scope)
        let request = Task {
            try await session.data(from: URL(string: "http://stub.test/suspended")!)
        }
        for _ in 0..<50_000 {
            if URLProtocolStub.pendingResponseCount(scope: scope) == 1 { break }
            await Task.yield()
        }
        #expect(URLProtocolStub.pendingResponseCount(scope: scope) == 1)

        request.cancel()
        await #expect {
            try await request.value
        } throws: { error in
            error is CancellationError || (error as? URLError)?.code == .cancelled
        }
        #expect(URLProtocolStub.pendingResponseCount(scope: scope) == 0)

        URLProtocolStub.finish(scope: scope)
        #expect(URLProtocolStub.requests(scope: scope).isEmpty)
    }
}

@MainActor
private final class ABSBrowseModelFixture {
    static let authorOne = ABSFilterOption(group: .authors, value: "a1", label: "Author One")
    static let authorTwo = ABSFilterOption(group: .authors, value: "a2", label: "Author Two")
    static let history = ABSFilterOption(group: .genres, value: "History", label: "History")

    let db: DatabaseService
    let service: AudiobookshelfService
    let model: ABSBrowseModel
    let item: ABSLibraryItem

    let scope: String
    private let serverID: String
    private let preferences: UserDefaults
    private let preferencesSuiteName: String
    private var managedFolder: URL?

    var requests: [URLRequest] { URLProtocolStub.requests(scope: scope) }
    var pendingResponseCount: Int { URLProtocolStub.pendingResponseCount(scope: scope) }
    var requestedItemPages: [String] {
        requests.compactMap { request in
            guard request.url?.path.hasSuffix("/items") == true, let url = request.url else {
                return nil
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "page" })?.value
        }
    }
    var persistedSortRawValue: String? { preferences.string(forKey: "absBrowseSort") }

    init(
        importedRemoteID: String? = nil,
        importZipEntry: String? = nil
    ) throws {
        scope = "browse-http-\(UUID().uuidString)"
        URLProtocolStub.reset(scope: scope)
        serverID = "browse-\(UUID().uuidString)"
        preferencesSuiteName = "ABSBrowseModelTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferencesSuiteName)!
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        let tokens = ABSTokenStore(serverID: serverID)
        tokens.accessToken = "acc"
        db = try DatabaseService(inMemory: ())
        service = AudiobookshelfService(
            baseURL: URL(string: "http://browse.test:13378")!, tokens: tokens,
            session: URLProtocolStub.makeSession(scope: scope))

        model = ABSBrowseModel(
            service: service, db: db, serverID: serverID, debounce: .zero,
            preferences: preferences)

        item = try Self.decodeItem(id: "i1", libraryID: "l1")

        if let importedRemoteID {
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "ABSBrowseModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appending(path: "book.m4b"))
            managedFolder = folder
            try AudiobookDAO(db: db.writer).save(
                AudiobookRecord(
                    id: folder.absoluteString, title: "Imported", author: nil, duration: 0,
                    fileCount: 1, addedAt: "2026-08-12T00:00:00Z",
                    sourceType: "audiobookshelf", serverID: serverID,
                    remoteItemID: importedRemoteID))
        }

        if let importZipEntry {
            URLProtocolStub.stub(
                scope: scope, pathSuffix: "/download",
                data: try Self.makeZip(entry: importZipEntry))
        }
    }

    deinit {
        if let managedFolder { try? FileManager.default.removeItem(at: managedFolder) }
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        URLProtocolStub.finish(scope: scope)
    }

    func stubLibrariesAndEmptyItems() {
        stubLibraries(ids: ["l1"])
        stubFilterData()
        URLProtocolStub.stub(scope: scope, pathSuffix: "/items", json: itemsJSON(ids: []))
    }

    func stubLibraryItems(ids: [String]) {
        stubLibraries(ids: ["l1"])
        stubLibraryItems(ids: ids, libraryID: "l1")
    }

    func stubLibraries(ids: [String]) {
        let values = ids.map { #"{"id":"\#($0)","name":"Library \#($0)"}"# }
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/api/libraries",
            json: "{\"libraries\":[\(values.joined(separator: ","))]}")
    }

    func stubLibraryItems(ids: [String], libraryID: String) {
        stubFilterData(libraryID: libraryID)
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/api/libraries/\(libraryID)/items",
            json: itemsJSON(ids: ids, libraryID: libraryID))
    }

    func stubFilterData(libraryID: String = "l1") {
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/api/libraries/\(libraryID)",
            queryItems: ["include": "filterdata"],
            json: """
                {"filterdata":{"authors":[{"id":"a1","name":"Author One"},{"id":"a2","name":"Author Two"}],"series":[],"genres":["History"],"tags":[]}}
                """)
    }

    func stubFilteredItems(
        option: ABSFilterOption, ids: [String], libraryID: String = "l1"
    ) {
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/api/libraries/\(libraryID)/items",
            queryItems: ["filter": option.encodedFilter],
            json: itemsJSON(ids: ids, libraryID: libraryID))
    }

    func stubPagedItems(
        page: Int, ids: [String], total: Int, suspended: Bool = false
    ) {
        stubLibraries(ids: ["l1"])
        stubFilterData()
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/items", queryItems: ["page": String(page)],
            json: itemsJSON(ids: ids, total: total, limit: 1, page: page), suspended: suspended)
    }

    func stubSearch(query: String, ids: [String], suspended: Bool = false) {
        let books = ids.map { id in
            "{\"libraryItem\":\(itemJSON(id: id, libraryID: "l1"))}"
        }.joined(separator: ",")
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/search", queryItems: ["q": query],
            json: "{\"book\":[\(books)],\"authors\":[]}", suspended: suspended)
    }

    func itemsJSON(
        ids: [String], libraryID: String = "l1", total: Int? = nil,
        limit: Int? = nil, page: Int = 0
    ) -> String {
        let items = ids.map { itemJSON(id: $0, libraryID: libraryID) }.joined(separator: ",")
        let total = total ?? ids.count
        let limitJSON = limit.map { ",\"limit\":\($0)" } ?? ""
        return "{\"total\":\(total),\"page\":\(page)\(limitJSON),\"results\":[\(items)]}"
    }

    func stub(
        pathSuffix: String, queryItems: [String: String], json: String,
        suspended: Bool = false
    ) {
        URLProtocolStub.stub(
            scope: scope, pathSuffix: pathSuffix, queryItems: queryItems,
            json: json, suspended: suspended)
    }

    func resume(pathSuffix: String, queryItems: [String: String]) {
        URLProtocolStub.resume(scope: scope, pathSuffix: pathSuffix, queryItems: queryItems)
    }

    @discardableResult
    func insertUsableProvenance(remoteID: String, folderName: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ABSBrowseModelTests-\(scope)", directoryHint: .isDirectory)
        let folder = root.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "book.m4b"))
        managedFolder = root
        try AudiobookDAO(db: db.writer).save(
            AudiobookRecord(
                id: folder.absoluteString, title: folderName, author: nil, duration: 0,
                fileCount: 1, addedAt: "2026-08-12T00:00:00Z",
                sourceType: "audiobookshelf", serverID: serverID, remoteItemID: remoteID))
        return folder
    }

    func makeReloadedModel() -> ABSBrowseModel {
        ABSBrowseModel(
            service: service, db: db, serverID: serverID, debounce: .zero,
            preferences: preferences)
    }

    private func itemJSON(id: String, libraryID: String) -> String {
        let suffix = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return """
            {"id":"\(id)","libraryId":"\(libraryID)","addedAt":\(suffix),"media":{"metadata":{"title":"Title \(id)","author":"Author \(id)"}}}
            """
    }

    private static func decodeItem(id: String, libraryID: String) throws -> ABSLibraryItem {
        try JSONDecoder().decode(
            ABSLibraryItem.self,
            from: Data(
                "{\"id\":\"\(id)\",\"libraryId\":\"\(libraryID)\",\"media\":{\"metadata\":{\"title\":\"Book\"}}}"
                    .utf8))
    }

    private static func makeZip(entry: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "ABSBrowseModelTests-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        let data = Data("audio".utf8)
        try archive.addEntry(with: entry, type: .file, uncompressedSize: Int64(data.count)) {
            position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
        return try Data(contentsOf: url)
    }
}
