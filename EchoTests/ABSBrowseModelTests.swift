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

    @Test func notAddedDuringInitialLoadWaitsForCurrentResults() async throws {
        let fixture = try ABSBrowseModelFixture(importedRemoteID: "i1")
        fixture.stubLibraryItems(ids: ["i1", "i2"])
        fixture.stub(
            pathSuffix: "/api/libraries", queryItems: [:],
            json: #"{"libraries":[{"id":"l1","name":"Library"}]}"#,
            suspended: true)

        let load = Task { await fixture.model.load() }
        try await waitUntilRequest(in: fixture, pathSuffix: "/api/libraries")
        let projection = fixture.model.setNotAddedOnly(true)
        #expect(fixture.model.resultCompleteness == .empty)

        fixture.resume(pathSuffix: "/api/libraries", queryItems: [:])
        await load.value
        await projection.value

        #expect(fixture.model.displayedItems.map(\.id) == ["i2"])
        #expect(fixture.model.totalCount == 1)
        #expect(fixture.model.resultCompleteness == .complete)
    }

    @Test func notAddedDuringSuspendedSearchProjectsSearchResults() async throws {
        let fixture = try ABSBrowseModelFixture(importedRemoteID: "added")
        fixture.stubLibraryItems(ids: ["initial"])
        fixture.stubSearch(query: "needle", ids: ["added", "kept"], suspended: true)
        await fixture.model.load()

        let search = fixture.model.setSearchQuery("needle")
        try await waitUntilRequest(in: fixture, search: "needle")
        let projection = fixture.model.setNotAddedOnly(true)

        fixture.resume(pathSuffix: "/search", queryItems: ["q": "needle"])
        await search.value
        await projection.value

        #expect(fixture.model.displayedItems.map(\.id) == ["kept"])
        #expect(fixture.model.resultCompleteness == .complete)
    }

    @Test func disablingNotAddedDuringSuspendedSeriesLoadInvalidatesProjection() async throws {
        let fixture = try ABSBrowseModelFixture(importedRemoteID: "added")
        fixture.stubLibraryItems(ids: ["initial"])
        await fixture.model.load()
        fixture.stub(
            pathSuffix: "/items", queryItems: [:],
            json: fixture.itemsJSON(ids: ["added", "kept"]), suspended: true)

        let priorRequestCount = fixture.requests.count
        let series = fixture.model.setSort(.series)
        try await waitUntilRequest(
            in: fixture, pathSuffix: "/items", page: "0",
            afterRequestCount: priorRequestCount)
        let enabled = fixture.model.setNotAddedOnly(true)
        let disabled = fixture.model.setNotAddedOnly(false)

        fixture.resume(pathSuffix: "/items", queryItems: ["page": "0"])
        await series.value
        await enabled.value
        await disabled.value

        #expect(!fixture.model.selection.notAddedOnly)
        #expect(Set(fixture.model.displayedItems.map(\.id)) == ["added", "kept"])
        #expect(fixture.model.totalCount == 2)
    }

    @Test func disablingNotAddedInvalidatesSuspendedCompleteProjection() async throws {
        let fixture = try ABSBrowseModelFixture(importedRemoteID: "added")
        fixture.stubLibraryItems(ids: ["added", "kept"])
        let gate = FirstProjectionGate()
        let model = fixture.makeModel { items, addedIDs in
            await gate.suspendFirstProjection()
            return try ABSBrowseResultResolver.excludingAddedCancellable(
                items, addedIDs: addedIDs)
        }
        await model.load()

        let enabled = model.setNotAddedOnly(true)
        try await gate.waitUntilSuspended()
        let projectionDidSuspend = await gate.hasSuspendedProjection
        #expect(projectionDidSuspend)
        let disabled = model.setNotAddedOnly(false)
        await disabled.value
        await gate.resumeProjection()
        await enabled.value

        #expect(!model.selection.notAddedOnly)
        #expect(Set(model.displayedItems.map(\.id)) == ["added", "kept"])
        #expect(model.totalCount == 2)
    }

    @Test func notAddedTransitionDoesNotCancelSuspendedMultiFilterLoad() async throws {
        let fixture = try ABSBrowseModelFixture(importedRemoteID: "added")
        fixture.stubLibraryItems(ids: ["initial"])
        fixture.stubFilterData()
        fixture.stubFilteredItems(option: ABSBrowseModelFixture.authorTwo, ids: ["added", "kept"])
        fixture.stub(
            pathSuffix: "/items",
            queryItems: ["filter": ABSBrowseModelFixture.authorOne.encodedFilter],
            json: fixture.itemsJSON(ids: ["added", "kept"]), suspended: true)
        await fixture.model.load()

        let priorRequestCount = fixture.requests.count
        let firstFilter = fixture.model.toggleFilter(ABSBrowseModelFixture.authorOne)
        try await waitUntilRequest(
            in: fixture, pathSuffix: "/items",
            filter: ABSBrowseModelFixture.authorOne.encodedFilter,
            afterRequestCount: priorRequestCount)
        try await waitUntilPendingResponseCount(1, in: fixture)
        let multiFilter = fixture.model.toggleFilter(ABSBrowseModelFixture.authorTwo)
        await firstFilter.value
        try await waitUntilRequest(
            in: fixture, pathSuffix: "/items",
            filter: ABSBrowseModelFixture.authorOne.encodedFilter,
            afterRequestCount: priorRequestCount + 1)
        try await waitUntilPendingResponseCount(1, in: fixture)
        let projection = fixture.model.setNotAddedOnly(true)

        fixture.resume(
            pathSuffix: "/items",
            queryItems: ["filter": ABSBrowseModelFixture.authorOne.encodedFilter])
        await multiFilter.value
        await projection.value

        #expect(fixture.model.displayedItems.map(\.id) == ["kept"])
        #expect(fixture.model.resultCompleteness == .complete)
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
        try await waitUntilPendingResponseCount(0, in: fixture)

        #expect(fixture.pendingResponseCount == 0)
    }

    @Test func canceledOlderCallerCannotCancelNewerBrowseTask() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraryItems(ids: ["initial"])
        await fixture.model.load()
        fixture.stub(
            pathSuffix: "/api/libraries", queryItems: [:],
            json: #"{"libraries":[{"id":"l1","name":"Library"}]}"#,
            suspended: true)
        fixture.stub(
            pathSuffix: "/items", queryItems: ["sort": "media.metadata.title"],
            json: fixture.itemsJSON(ids: ["current"]), suspended: true)

        let priorRequestCount = fixture.requests.count
        let oldCaller = Task { await fixture.model.refresh() }
        try await waitUntilRequest(
            in: fixture, pathSuffix: "/api/libraries",
            afterRequestCount: priorRequestCount)
        oldCaller.cancel()
        let current = fixture.model.setSort(.title)
        try await waitUntilRequest(in: fixture, sort: "media.metadata.title")
        await oldCaller.value

        fixture.resume(pathSuffix: "/items", queryItems: ["sort": "media.metadata.title"])
        await current.value

        #expect(fixture.model.displayedItems.map(\.id) == ["current"])
        #expect(fixture.model.loadState == .loaded)
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
        try await waitUntilPendingResponseCount(0, in: fixture)

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

    @Test func seriesCategoryAtServerCapIsLimitedAfterStableDeduplication() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibrariesAndEmptyItems()
        fixture.stubSeriesSearch(query: "Saga", seriesCount: 10_000, repeatedItemID: "same")
        await fixture.model.load()

        await fixture.model.setSearchQuery("Saga").value

        #expect(fixture.model.displayedItems.map(\.id) == ["same"])
        #expect(fixture.model.totalCount == 1)
        #expect(fixture.model.searchResultsAreLimited)
        #expect(fixture.model.resultCompleteness == .partial)
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

    @Test func importProgressMapsToOrderedRunningStagesBeforeAdded() async throws {
        let extractionGate = ABSBrowseImportGate()
        let persistenceGate = ABSBrowseImportGate()
        let fixture = try ABSBrowseModelFixture(
            importZipEntry: "book.m4b",
            importDownloadSuspended: true,
            afterExtractedEntry: { await extractionGate.suspend() },
            afterPersistence: { await persistenceGate.suspend() })

        let importTask = Task { await fixture.model.add(fixture.item) }
        try await waitUntilPendingResponseCount(1, in: fixture)
        guard case .running(let download, _) = fixture.model.importState(for: fixture.item.id)
        else {
            Issue.record("Expected downloading state")
            fixture.model.cancelImport()
            await importTask.value
            return
        }
        #expect(download.stage == .downloading)

        fixture.resume(pathSuffix: "/download", queryItems: [:])
        await extractionGate.waitUntilSuspended()
        guard case .running(let extraction, _) = fixture.model.importState(for: fixture.item.id)
        else {
            Issue.record("Expected extracting state")
            await extractionGate.release()
            fixture.model.cancelImport()
            await importTask.value
            return
        }
        #expect(extraction.stage == .extracting)

        await extractionGate.release()
        await persistenceGate.waitUntilSuspended()
        guard case .running(let adding, _) = fixture.model.importState(for: fixture.item.id)
        else {
            Issue.record("Expected adding-to-Echo state")
            await persistenceGate.release()
            fixture.model.cancelImport()
            await importTask.value
            return
        }
        #expect(adding.stage == .addingToEcho)

        await persistenceGate.release()
        await importTask.value
        guard case .added = fixture.model.importState(for: fixture.item.id) else {
            Issue.record("Expected Added state")
            return
        }
    }

    @Test func onlyOneImportRunsAtATime() async throws {
        let fixture = try ABSBrowseModelFixture(
            importZipEntry: "book.m4b", importDownloadSuspended: true)
        let secondItem = try fixture.makeItem(id: "second-\(UUID().uuidString)")

        let firstImport = Task { await fixture.model.add(fixture.item) }
        try await waitUntilPendingResponseCount(1, in: fixture)
        await fixture.model.add(secondItem)

        #expect(fixture.model.activeImportItemID == fixture.item.id)
        #expect(fixture.model.importState(for: secondItem.id) == .ready)
        #expect(fixture.requests.count { $0.url?.path.hasSuffix("/download") == true } == 1)

        fixture.model.cancelImport()
        await firstImport.value
    }

    @Test func cancelRetainsRetryableFailureAtCurrentStage() async throws {
        let fixture = try ABSBrowseModelFixture(
            importZipEntry: "book.m4b", importDownloadSuspended: true)
        let importTask = Task { await fixture.model.add(fixture.item) }
        try await waitUntilPendingResponseCount(1, in: fixture)

        fixture.model.cancelImport()
        await importTask.value

        guard case .failed(let failure) = fixture.model.importState(for: fixture.item.id) else {
            Issue.record("Expected visible cancellation failure")
            return
        }
        #expect(failure.stage == .downloading)
        #expect(failure.isRetryable)
        #expect(!failure.message.isEmpty)
        #expect(fixture.model.activeImportItemID == nil)
    }

    @Test func importFailureRemainsVisibleWithNamedStage() async throws {
        let fixture = try ABSBrowseModelFixture(importDownloadData: Data("not-a-zip".utf8))

        await fixture.model.add(fixture.item)

        guard case .failed(let failure) = fixture.model.importState(for: fixture.item.id) else {
            Issue.record("Expected visible import failure")
            return
        }
        #expect(failure.stage == .extracting)
        #expect(!failure.message.isEmpty)
    }

    @Test func retryReplacesFailureWithFreshRunningState() async throws {
        let fixture = try ABSBrowseModelFixture(importDownloadData: Data("not-a-zip".utf8))
        await fixture.model.add(fixture.item)
        guard case .failed = fixture.model.importState(for: fixture.item.id) else {
            Issue.record("Expected initial failure")
            return
        }
        try fixture.stubImport(zipEntry: "book.m4b", suspended: true)

        let retry = Task { await fixture.model.retryImport(fixture.item) }
        try await waitUntilPendingResponseCount(1, in: fixture)

        guard case .running(let progress, _) = fixture.model.importState(for: fixture.item.id)
        else {
            Issue.record("Expected retry to reset running state")
            fixture.model.cancelImport()
            await retry.value
            return
        }
        #expect(progress.stage == .downloading)
        fixture.model.cancelImport()
        await retry.value
    }

    @Test func successRetainsAddedStateAndOpenTarget() async throws {
        let fixture = try ABSBrowseModelFixture(importZipEntry: "book.m4b")

        await fixture.model.add(fixture.item)

        guard case .added(let book) = fixture.model.importState(for: fixture.item.id) else {
            Issue.record("Expected Added state")
            return
        }
        #expect(fixture.model.openTarget(for: fixture.item.id) == book)
        #expect(fixture.model.addedBooksByRemoteID[fixture.item.id] == book)
        #expect(ABSLocalImportStatus.hasSupportedRootContent(at: book.folderURL))
    }

    @Test func successfulImportImmediatelyLeavesNotAddedResults() async throws {
        let fixture = try ABSBrowseModelFixture(importZipEntry: "book.m4b")
        fixture.stubLibraryItems(ids: [fixture.item.id])
        await fixture.model.load()
        await fixture.model.setNotAddedOnly(true).value
        #expect(fixture.model.displayedItems.map(\.id) == [fixture.item.id])
        let itemRequestCount =
            fixture.requests.count { $0.url?.path.hasSuffix("/items") == true }

        await fixture.model.add(fixture.item)

        #expect(fixture.model.displayedItems.isEmpty)
        #expect(fixture.model.totalCount == 0)
        #expect(
            fixture.requests.count { $0.url?.path.hasSuffix("/items") == true }
                == itemRequestCount)
    }

    @Test func importSuccessInvalidatesSuspendedNotAddedProjection() async throws {
        let gate = FirstProjectionGate()
        let fixture = try ABSBrowseModelFixture(
            importZipEntry: "book.m4b",
            notAddedProjection: { items, addedIDs in
                await gate.suspendFirstProjection()
                return try ABSBrowseResultResolver.excludingAddedCancellable(
                    items, addedIDs: addedIDs)
            })
        fixture.stubLibraryItems(ids: [fixture.item.id])
        await fixture.model.load()

        let projection = fixture.model.setNotAddedOnly(true)
        try await gate.waitUntilSuspended()
        #expect(await gate.hasSuspendedProjection)

        await fixture.model.add(fixture.item)
        await gate.resumeProjection()
        await projection.value

        #expect(fixture.model.displayedItems.isEmpty)
        #expect(fixture.model.totalCount == 0)
    }

    @Test func staleProvenanceReloadCannotEraseSuccessfulImport() async throws {
        let gate = NextAsyncGate()
        let fixture = try ABSBrowseModelFixture(
            importZipEntry: "book.m4b",
            afterAddedBooksLoad: { await gate.suspendIfArmed() })
        fixture.stubLibraryItems(ids: [fixture.item.id])
        await fixture.model.load()
        await fixture.model.setNotAddedOnly(true).value
        await gate.arm()

        let refresh = Task { await fixture.model.refresh() }
        try await gate.waitUntilSuspended()
        await fixture.model.add(fixture.item)
        await gate.release()
        await refresh.value

        guard case .added(let book) = fixture.model.importState(for: fixture.item.id) else {
            Issue.record("Expected Added state after stale provenance reload")
            return
        }
        #expect(fixture.model.addedBooksByRemoteID[fixture.item.id] == book)
        #expect(fixture.model.displayedItems.isEmpty)
        #expect(fixture.model.totalCount == 0)
    }

    @Test(arguments: RemovedImportArtifact.allCases)
    func freshProvenanceReloadClearsRemovedSuccessfulImport(
        _ removedArtifact: RemovedImportArtifact
    ) async throws {
        let fixture = try ABSBrowseModelFixture(importZipEntry: "book.m4b")
        fixture.stubLibraryItems(ids: [fixture.item.id])
        await fixture.model.load()
        await fixture.model.setNotAddedOnly(true).value
        await fixture.model.add(fixture.item)
        guard case .added(let book) = fixture.model.importState(for: fixture.item.id) else {
            Issue.record("Expected Added state before removing local provenance")
            return
        }
        try fixture.removeImportedBook(book, artifact: removedArtifact)

        await fixture.model.refresh()

        #expect(fixture.model.importState(for: fixture.item.id) == .ready)
        #expect(fixture.model.openTarget(for: fixture.item.id) == nil)
        #expect(fixture.model.addedBooksByRemoteID[fixture.item.id] == nil)
        #expect(fixture.model.displayedItems.map(\.id) == [fixture.item.id])
        #expect(fixture.model.totalCount == 1)
    }

    @Test func staleSnapshotRetainsOnlyImportThatCompletedAfterItStarted() async throws {
        let gate = NextAsyncGate()
        let fixture = try ABSBrowseModelFixture(
            importZipEntry: "book.m4b",
            afterAddedBooksLoad: { await gate.suspendIfArmed() })
        let newerItem = try fixture.makeItem(id: "newer-\(UUID().uuidString)")
        fixture.stubLibraryItems(ids: [fixture.item.id, newerItem.id])
        await fixture.model.load()
        await fixture.model.setNotAddedOnly(true).value
        await fixture.model.add(fixture.item)
        guard case .added(let olderBook) = fixture.model.importState(for: fixture.item.id)
        else {
            Issue.record("Expected first import to reach Added")
            return
        }
        try fixture.removeImportedBook(olderBook, artifact: .usableFolder)
        await gate.arm()

        let refresh = Task { await fixture.model.refresh() }
        try await gate.waitUntilSuspended()
        await fixture.model.add(newerItem)
        await gate.release()
        await refresh.value

        #expect(fixture.model.importState(for: fixture.item.id) == .ready)
        #expect(fixture.model.openTarget(for: fixture.item.id) == nil)
        #expect(fixture.model.displayedItems.map(\.id) == [fixture.item.id])
        guard case .added(let newerBook) = fixture.model.importState(for: newerItem.id) else {
            Issue.record("Expected concurrent import to remain Added")
            return
        }
        #expect(fixture.model.openTarget(for: newerItem.id) == newerBook)
        #expect(fixture.model.addedBooksByRemoteID[newerItem.id] == newerBook)
    }

    @Test func importSuccessDoesNotCancelSuspendedNotAddedDisableProjection() async throws {
        let gate = NextAsyncGate()
        let fixture = try ABSBrowseModelFixture(
            importZipEntry: "book.m4b",
            notAddedProjection: { items, addedIDs in
                await gate.suspendIfArmed()
                return try ABSBrowseResultResolver.excludingAddedCancellable(
                    items, addedIDs: addedIDs)
            })
        fixture.stubLibraryItems(ids: [fixture.item.id])
        await fixture.model.load()
        await gate.arm()

        let hideAdded = fixture.model.setNotAddedOnly(true)
        try await gate.waitUntilSuspended()
        let showAll = fixture.model.setNotAddedOnly(false)
        await fixture.model.add(fixture.item)
        await gate.release()
        await hideAdded.value
        await showAll.value

        #expect(!fixture.model.selection.notAddedOnly)
        #expect(fixture.model.displayedItems.map(\.id) == [fixture.item.id])
        #expect(fixture.model.totalCount == 1)
    }

    @Test func multiFilterFanOutNeverExceedsFourConcurrentQueries() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibraryItems(ids: [])
        await fixture.model.load()
        let options = (0..<5).map {
            ABSFilterOption(group: .tags, value: "tag-\($0)", label: "Tag \($0)")
        }
        for option in options {
            fixture.stubFilteredItems(option: option, ids: [], suspended: true)
        }
        fixture.model.selection.options = Set(options)

        let refresh = Task { await fixture.model.refresh() }
        try await waitUntilPendingResponseCount(4, in: fixture)
        #expect(fixture.pendingResponseCount == 4)
        #expect(fixture.requestedFilters.count == 4)

        let admittedFilter = try #require(fixture.requestedFilters.first)
        fixture.resume(
            pathSuffix: "/items", queryItems: ["filter": admittedFilter])
        try await waitUntilFilterRequestCount(5, in: fixture)
        #expect(fixture.pendingResponseCount == 4)

        fixture.model.cancel()
        await refresh.value
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
        filter: String? = nil,
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
                if let filter, !query.contains(.init(name: "filter", value: filter)) {
                    return false
                }
                return true
            }) {
                return
            }
            await Task.yield()
        }
        throw TimeoutError()
    }

    private func waitUntilPendingResponseCount(
        _ count: Int, in fixture: ABSBrowseModelFixture
    ) async throws {
        for _ in 0..<50_000 {
            if fixture.pendingResponseCount == count { return }
            await Task.yield()
        }
        throw TimeoutError()
    }

    private func waitUntilFilterRequestCount(
        _ count: Int, in fixture: ABSBrowseModelFixture
    ) async throws {
        for _ in 0..<50_000 {
            if fixture.requestedFilters.count == count { return }
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
        // `request.value` resumes as soon as the cancellation error is delivered,
        // but the pending entry is dropped by `stopLoading()` on URLSession's own
        // thread, which lands afterwards — measured at a median of 16 yields and
        // up to 485. Wait for it the same way the arming check above does; without
        // this the assertion reads a stale 1 whenever the runner is busy.
        for _ in 0..<50_000 {
            if URLProtocolStub.pendingResponseCount(scope: scope) == 0 { break }
            await Task.yield()
        }
        #expect(URLProtocolStub.pendingResponseCount(scope: scope) == 0)

        URLProtocolStub.finish(scope: scope)
        #expect(URLProtocolStub.requests(scope: scope).isEmpty)
    }

    @Test func cancellationAfterResumeRemovalPreventsLateDelivery() async throws {
        let scope = "url-stub-resume-cancel-\(UUID().uuidString)"
        defer { URLProtocolStub.finish(scope: scope) }
        URLProtocolStub.reset(scope: scope)
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/suspended", json: #"{"value":1}"#,
            suspended: true)
        let session = URLProtocolStub.makeSession(scope: scope)
        let request = Task {
            try await session.data(from: URL(string: "http://stub.test/suspended")!)
        }
        for _ in 0..<50_000 {
            if URLProtocolStub.pendingResponseCount(scope: scope) == 1 { break }
            await Task.yield()
        }
        #expect(URLProtocolStub.pendingResponseCount(scope: scope) == 1)

        let resume = Task {
            URLProtocolStub.resume(scope: scope, pathSuffix: "/suspended") { stub in
                request.cancel()
                stub.stopLoading()
            }
        }
        await resume.value
        await #expect {
            try await request.value
        } throws: { error in
            error is CancellationError || (error as? URLError)?.code == .cancelled
        }
        #expect(URLProtocolStub.pendingResponseCount(scope: scope) == 0)
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
    private var managedRemoteItemIDs: Set<String> = []

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
    var requestedFilters: [String] {
        requests.compactMap { request in
            guard request.url?.path.hasSuffix("/items") == true, let url = request.url else {
                return nil
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "filter" })?.value
        }
    }
    var persistedSortRawValue: String? { preferences.string(forKey: "absBrowseSort") }

    init(
        importedRemoteID: String? = nil,
        importZipEntry: String? = nil,
        importDownloadData: Data? = nil,
        importDownloadSuspended: Bool = false,
        afterExtractedEntry: @escaping @Sendable () async -> Void = {},
        afterPersistence: @escaping @Sendable () async -> Void = {},
        notAddedProjection: ABSBrowseModel.NotAddedProjection? = nil,
        afterAddedBooksLoad: @escaping @MainActor @Sendable () async -> Void = {}
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
        item = try Self.decodeItem(id: "browse-item-\(UUID().uuidString)", libraryID: "l1")
        managedRemoteItemIDs.insert(item.id)
        if let importZipEntry {
            URLProtocolStub.stub(
                scope: scope, pathSuffix: "/download",
                data: try Self.makeZip(entry: importZipEntry),
                headers: ["Content-Type": "application/zip"],
                suspended: importDownloadSuspended)
        } else if let importDownloadData {
            URLProtocolStub.stub(
                scope: scope, pathSuffix: "/download", data: importDownloadData,
                headers: ["Content-Type": "application/zip"],
                suspended: importDownloadSuspended)
        }
        let importer = ABSImportService(
            service: service, db: db, serverID: serverID,
            afterExtractedEntry: afterExtractedEntry,
            afterPersistence: afterPersistence)
        model = ABSBrowseModel(
            service: service, db: db, serverID: serverID, debounce: .zero,
            preferences: preferences, notAddedProjection: notAddedProjection,
            importService: importer, afterAddedBooksLoad: afterAddedBooksLoad)

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

    }

    isolated deinit {
        if let managedFolder { try? FileManager.default.removeItem(at: managedFolder) }
        for itemID in managedRemoteItemIDs {
            let finalFolder = FileLocations.absLibraryDirectory(remoteItemID: itemID)
            let residues =
                (try? FileManager.default.contentsOfDirectory(
                    at: finalFolder.deletingLastPathComponent(),
                    includingPropertiesForKeys: nil))?.filter {
                    $0.lastPathComponent.contains(itemID)
                } ?? []
            try? FileManager.default.removeItem(at: finalFolder)
            for residue in residues { try? FileManager.default.removeItem(at: residue) }
        }
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
        option: ABSFilterOption, ids: [String], libraryID: String = "l1",
        suspended: Bool = false
    ) {
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/api/libraries/\(libraryID)/items",
            queryItems: ["filter": option.encodedFilter],
            json: itemsJSON(ids: ids, libraryID: libraryID), suspended: suspended)
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

    func stubSeriesSearch(query: String, seriesCount: Int, repeatedItemID: String) {
        let item = itemJSON(id: repeatedItemID, libraryID: "l1")
        let series = (0..<seriesCount).map { index in
            "{\"series\":{\"id\":\"s\(index)\",\"name\":\"Saga \(index)\"},\"books\":[\(item)]}"
        }.joined(separator: ",")
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/search", queryItems: ["q": query],
            json: "{\"book\":[],\"podcast\":[],\"authors\":[],\"series\":[\(series)]}")
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

    func stubImport(zipEntry: String, suspended: Bool = false) throws {
        URLProtocolStub.stub(
            scope: scope, pathSuffix: "/download",
            data: try Self.makeZip(entry: zipEntry),
            headers: ["Content-Type": "application/zip"], suspended: suspended)
    }

    func makeItem(id: String) throws -> ABSLibraryItem {
        managedRemoteItemIDs.insert(id)
        return try Self.decodeItem(id: id, libraryID: "l1")
    }

    func removeImportedBook(
        _ book: ABSImportedBook,
        artifact: RemovedImportArtifact
    ) throws {
        switch artifact {
        case .provenance:
            try AudiobookDAO(db: db.writer).delete(book.folderURL.absoluteString)
        case .usableFolder:
            try FileManager.default.removeItem(at: book.folderURL)
        }
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

    func makeModel(
        notAddedProjection: @escaping ABSBrowseModel.NotAddedProjection
    ) -> ABSBrowseModel {
        ABSBrowseModel(
            service: service, db: db, serverID: serverID, debounce: .zero,
            preferences: preferences, notAddedProjection: notAddedProjection)
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

private actor ABSBrowseImportGate {
    private var suspended = false
    private var released = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        suspendedWaiters.forEach { $0.resume() }
        suspendedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspendedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

enum RemovedImportArtifact: CaseIterable, Sendable {
    case provenance
    case usableFolder
}

private actor NextAsyncGate {
    private var armed = false
    private var suspended = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
    }

    func suspendIfArmed() async {
        guard armed else { return }
        armed = false
        suspended = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async throws {
        // `suspended` is flipped by main-actor work several hops away, but this
        // poll reads the gate's own state and never touches the main actor — so a
        // `Task.yield()` budget is spent at full speed however starved that work
        // is. Measured, 50_000 yields is about 200 ms of real time no matter how
        // long the awaited side needs, which is what timed this out on CI. Bound
        // the wait in wall-clock time instead, and sleep rather than spin so the
        // poll stops competing for the cores the awaited work needs.
        let deadline = ContinuousClock.now + .seconds(30)
        while !suspended {
            if ContinuousClock.now >= deadline { throw NextAsyncGateTimeoutError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct NextAsyncGateTimeoutError: Error {}

private struct FirstProjectionGateTimeoutError: Error {}

private actor FirstProjectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasSuspendedProjection = false
    private var didSuspend = false

    /// Same wall-clock bound as `NextAsyncGate.waitUntilSuspended()`, and for the
    /// same reason: the projection that flips this flag runs on the main actor,
    /// while the poll only ever touches this gate. The two call sites used to spin
    /// 50_000 yields inline and then fall through to `#expect` — so a starved
    /// projection was reported as "the projection never suspended" rather than as
    /// a timeout.
    func waitUntilSuspended() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !hasSuspendedProjection {
            if ContinuousClock.now >= deadline { throw FirstProjectionGateTimeoutError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func suspendFirstProjection() async {
        guard !didSuspend else { return }
        didSuspend = true
        hasSuspendedProjection = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resumeProjection() {
        continuation?.resume()
        continuation = nil
    }
}
