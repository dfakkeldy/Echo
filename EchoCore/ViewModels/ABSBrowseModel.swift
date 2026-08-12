// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

// ABS library items are immutable decoded value graphs. This conformance lets the
// browse model move complete-result set algebra and sorting off the UI actor.
extension ABSLibraryItem: @unchecked Sendable {}

@MainActor @Observable
final class ABSBrowseModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private static let sortPreferenceKey = "absBrowseSort"
    private static let pageSize = 100
    private static let searchLimit = 10_000
    private static let maximumConcurrentFilterQueries = 4

    @ObservationIgnored private let service: AudiobookshelfService
    @ObservationIgnored private let db: DatabaseService
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextPage: Int?
    @ObservationIgnored private var serverTotal: Int?

    let serverID: String
    var libraries: [ABSLibrary] = []
    var selectedLibraryID: String?
    var items: [ABSLibraryItem] = []
    var displayedItems: [ABSLibraryItem] = []
    var filterData = ABSLibraryFilterData.empty
    var selection = ABSFilterSelection()
    var sort: ABSBrowseSort
    var searchQuery = ""
    var totalCount: Int?
    var searchResultsAreLimited = false
    var loadState: LoadState = .idle
    var isLoadingNextPage = false
    private(set) var addedBooksByRemoteID: [String: ABSImportedBook] = [:]

    init(
        service: AudiobookshelfService,
        db: DatabaseService,
        serverID: String,
        debounce: Duration = .milliseconds(300),
        preferences: UserDefaults = .standard
    ) {
        self.service = service
        self.db = db
        self.serverID = serverID
        self.debounce = debounce
        self.preferences = preferences
        sort =
            preferences.string(forKey: Self.sortPreferenceKey)
            .flatMap(ABSBrowseSort.init(rawValue:)) ?? .newestAdded
    }

    func load() async {
        let task = replaceTask(clearResults: true) { model, generation in
            try await model.loadRoot(generation: generation)
        }
        await waitForOwnedTask(task)
    }

    @discardableResult
    func selectLibrary(_ libraryID: String?) -> Task<Void, Never> {
        guard selectedLibraryID != libraryID else { return completedTask() }
        selectedLibraryID = libraryID
        selection.options.removeAll()
        filterData = .empty
        return startSelectedLibraryLoad(clearResults: true, reloadFilterData: true)
    }

    @discardableResult
    func setSort(_ newSort: ABSBrowseSort) -> Task<Void, Never> {
        guard sort != newSort else { return completedTask() }
        sort = newSort
        preferences.set(newSort.rawValue, forKey: Self.sortPreferenceKey)
        return startSelectedLibraryLoad(clearResults: true, reloadFilterData: false)
    }

    @discardableResult
    func toggleFilter(_ option: ABSFilterOption) -> Task<Void, Never> {
        if selection.options.remove(option) == nil {
            selection.options.insert(option)
        }
        return startSelectedLibraryLoad(clearResults: true, reloadFilterData: false)
    }

    @discardableResult
    func setNotAddedOnly(_ enabled: Bool) -> Task<Void, Never> {
        guard selection.notAddedOnly != enabled else { return completedTask() }
        selection.notAddedOnly = enabled
        if enabled, trimmedSearchQuery.isEmpty, nextPage != nil {
            return startSelectedLibraryLoad(clearResults: false, reloadFilterData: false)
        }
        if enabled {
            return replaceTask(clearResults: false) { model, generation in
                try await model.republishCompleteResults(generation: generation)
            }
        }
        publishDisplayedItems()
        return completedTask()
    }

    @discardableResult
    func clearFilters() -> Task<Void, Never> {
        let hadMetadataFilters = !selection.options.isEmpty
        selection = ABSFilterSelection()
        if hadMetadataFilters {
            return startSelectedLibraryLoad(clearResults: true, reloadFilterData: false)
        } else {
            publishDisplayedItems()
            return completedTask()
        }
    }

    @discardableResult
    func setSearchQuery(_ query: String) -> Task<Void, Never> {
        guard searchQuery != query else { return completedTask() }
        searchQuery = query
        return startSelectedLibraryLoad(
            clearResults: true, reloadFilterData: false, debounceSearch: true)
    }

    func refresh() async {
        let task = replaceTask(clearResults: false) { model, generation in
            try await model.refreshRoot(generation: generation)
        }
        await waitForOwnedTask(task)
    }

    func loadNextPageIfNeeded() async {
        guard loadState == .loaded,
            let libraryID = selectedLibraryID,
            let page = nextPage,
            trimmedSearchQuery.isEmpty,
            sort != .series,
            selection.options.count <= 1,
            !isLoadingNextPage
        else { return }

        let activeGeneration = generation
        isLoadingNextPage = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadNextPage(
                libraryID: libraryID, page: page, generation: activeGeneration)
        }
        browseTask = task
        await waitForOwnedTask(task)
    }

    func cancel() {
        browseTask?.cancel()
        browseTask = nil
        generation += 1
        isLoadingNextPage = false
        loadState = .idle
    }

    private func loadRoot(generation: Int) async throws {
        let fetchedLibraries = try await service.libraries()
        try Task.checkCancellation()
        guard self.generation == generation else { return }

        libraries = fetchedLibraries
        if !fetchedLibraries.contains(where: { $0.id == selectedLibraryID }) {
            selectedLibraryID = fetchedLibraries.first?.id
            selection.options.removeAll()
        }
        try await loadAddedBooks()

        guard selectedLibraryID != nil else {
            filterData = .empty
            items = []
            displayedItems = []
            totalCount = 0
            nextPage = nil
            searchResultsAreLimited = false
            loadState = .loaded
            return
        }
        try await loadSelectedLibrary(
            generation: generation, reloadFilterData: true, debounceSearch: false)
    }

    private func refreshRoot(generation: Int) async throws {
        let fetchedLibraries = try await service.libraries()
        try Task.checkCancellation()
        guard self.generation == generation else { return }

        libraries = fetchedLibraries
        if !fetchedLibraries.contains(where: { $0.id == selectedLibraryID }) {
            selectedLibraryID = fetchedLibraries.first?.id
            selection.options.removeAll()
        }
        try await loadAddedBooks()
        guard selectedLibraryID != nil else {
            filterData = .empty
            items = []
            displayedItems = []
            totalCount = 0
            nextPage = nil
            searchResultsAreLimited = false
            loadState = .loaded
            return
        }
        try await loadSelectedLibrary(
            generation: generation, reloadFilterData: true, debounceSearch: false)
    }

    @discardableResult
    private func startSelectedLibraryLoad(
        clearResults: Bool,
        reloadFilterData: Bool,
        debounceSearch: Bool = false
    ) -> Task<Void, Never> {
        replaceTask(clearResults: clearResults) { model, generation in
            try await model.loadSelectedLibrary(
                generation: generation,
                reloadFilterData: reloadFilterData,
                debounceSearch: debounceSearch)
        }
    }

    @discardableResult
    private func replaceTask(
        clearResults: Bool,
        operation: @escaping @MainActor (ABSBrowseModel, Int) async throws -> Void
    ) -> Task<Void, Never> {
        browseTask?.cancel()
        generation += 1
        let activeGeneration = generation
        isLoadingNextPage = false
        loadState = .loading
        if clearResults {
            items = []
            displayedItems = []
            totalCount = nil
            serverTotal = nil
            nextPage = nil
            searchResultsAreLimited = false
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == activeGeneration { self.browseTask = nil }
            }
            do {
                try await operation(self, activeGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == activeGeneration else { return }
                self.isLoadingNextPage = false
                self.loadState = .failed(error.localizedDescription)
            }
        }
        browseTask = task
        return task
    }

    private func loadSelectedLibrary(
        generation: Int,
        reloadFilterData: Bool,
        debounceSearch: Bool
    ) async throws {
        guard let libraryID = selectedLibraryID else {
            guard self.generation == generation else { return }
            filterData = .empty
            items = []
            displayedItems = []
            totalCount = 0
            loadState = .loaded
            return
        }

        if reloadFilterData {
            let fetchedFilterData = try await service.libraryFilterData(libraryID: libraryID)
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            filterData = fetchedFilterData
        }

        if debounceSearch, !trimmedSearchQuery.isEmpty {
            try await Task.sleep(for: debounce)
            try Task.checkCancellation()
        }

        if trimmedSearchQuery.isEmpty {
            try await loadBrowseResults(libraryID: libraryID, generation: generation)
        } else {
            try await loadSearchResults(libraryID: libraryID, generation: generation)
        }
    }

    private func loadBrowseResults(libraryID: String, generation: Int) async throws {
        searchResultsAreLimited = false
        let options = Array(selection.options)

        if options.count > 1 {
            let optionResults = try await loadCompleteOptionResults(
                libraryID: libraryID, options: options)
            try Task.checkCancellation()
            guard self.generation == generation else { return }

            let selectedSort = sort
            let resolved = try await Self.offMain {
                try ABSBrowseResultResolver.resolvedCancellable(
                    optionResults: optionResults, sort: selectedSort)
            }
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            items = resolved
            serverTotal = resolved.count
            nextPage = nil
            try await publishCompleteResults(generation: generation)
            loadState = .loaded
            return
        }

        var query = ABSLibraryItemsQuery(limit: Self.pageSize, sort: sort)
        query.filter = options.first
        if sort == .series || selection.notAddedOnly {
            let allItems = try await service.allItems(libraryID: libraryID, query: query)
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            let selectedSort = sort
            let sortedItems = try await Self.offMain {
                try ABSBrowseResultResolver.sortedCancellable(allItems, by: selectedSort)
            }
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            items = sortedItems
            serverTotal = items.count
            nextPage = nil
            try await publishCompleteResults(generation: generation)
            loadState = .loaded
            return
        }

        let response = try await service.items(libraryID: libraryID, query: query)
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        items = response.results
        serverTotal = response.total
        nextPage = nextPage(after: response, requestedPage: 0, requestedLimit: Self.pageSize)
        publishDisplayedItems(completeResult: false)
        loadState = .loaded
    }

    private func loadSearchResults(libraryID: String, generation: Int) async throws {
        let query = trimmedSearchQuery
        async let searchResults = service.search(
            libraryID: libraryID, query: query, limit: Self.searchLimit)
        let options = Array(selection.options)
        let optionResults: [ABSFilterOption: [ABSLibraryItem]]
        if options.isEmpty {
            optionResults = [:]
        } else {
            optionResults = try await loadCompleteOptionResults(
                libraryID: libraryID, options: options)
        }
        let fetchedSearchResults = try await searchResults
        try Task.checkCancellation()
        guard self.generation == generation else { return }

        let selectedSort = sort
        let allowedIDs = try await Self.offMain {
            try Task.checkCancellation()
            return options.isEmpty
                ? nil
                : ABSBrowseResultResolver.combinedIDs(
                    filteredBy: Self.groupedIDs(optionResults: optionResults))
        }
        let sortedItems = try await Self.offMain {
            try ABSBrowseResultResolver.searchResultsCancellable(
                fetchedSearchResults, allowedIDs: allowedIDs, sort: selectedSort)
        }
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        items = sortedItems
        serverTotal = items.count
        nextPage = nil
        searchResultsAreLimited = fetchedSearchResults.count == Self.searchLimit
        try await publishCompleteResults(generation: generation)
        loadState = .loaded
    }

    private func loadCompleteOptionResults(
        libraryID: String,
        options: [ABSFilterOption]
    ) async throws -> [ABSFilterOption: [ABSLibraryItem]] {
        let selectedSort = sort
        var iterator = options.makeIterator()
        return try await withThrowingTaskGroup(
            of: (ABSFilterOption, [ABSLibraryItem]).self,
            returning: [ABSFilterOption: [ABSLibraryItem]].self
        ) { group in
            func addNext() {
                guard let option = iterator.next() else { return }
                group.addTask { @MainActor [service, selectedSort] in
                    var query = ABSLibraryItemsQuery(
                        limit: Self.pageSize, sort: selectedSort)
                    query.filter = option
                    return (
                        option,
                        try await service.allItems(libraryID: libraryID, query: query)
                    )
                }
            }

            for _ in 0..<min(Self.maximumConcurrentFilterQueries, options.count) { addNext() }
            var results: [ABSFilterOption: [ABSLibraryItem]] = [:]
            while let (option, items) = try await group.next() {
                results[option] = items
                addNext()
            }
            return results
        }
    }

    private nonisolated static func groupedIDs(
        optionResults: [ABSFilterOption: [ABSLibraryItem]]
    ) -> [ABSFilterGroup: [[String]]] {
        Dictionary(grouping: optionResults.keys, by: \.group).mapValues { options in
            options.map { optionResults[$0, default: []].map(\.id) }
        }
    }

    private nonisolated static func offMain<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func loadNextPage(libraryID: String, page: Int, generation: Int) async {
        defer {
            if self.generation == generation { isLoadingNextPage = false }
        }
        do {
            var query = ABSLibraryItemsQuery(page: page, limit: Self.pageSize, sort: sort)
            query.filter = selection.options.first
            let response = try await service.items(libraryID: libraryID, query: query)
            try Task.checkCancellation()
            guard self.generation == generation else { return }

            items.append(contentsOf: response.results)
            items = deduplicated(items)
            serverTotal = response.total ?? serverTotal
            nextPage = nextPage(
                after: response, requestedPage: page, requestedLimit: Self.pageSize)
            publishDisplayedItems(completeResult: false)
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard self.generation == generation else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    private func nextPage(
        after response: ABSLibraryItemsResponse,
        requestedPage: Int,
        requestedLimit: Int
    ) -> Int? {
        guard !response.results.isEmpty else { return nil }
        let page = response.page ?? requestedPage
        let limit = max(1, response.limit ?? requestedLimit)
        if response.results.count < limit { return nil }
        if let total = response.total, page * limit + response.results.count >= total { return nil }
        if let numPages = response.numPages, page + 1 >= numPages { return nil }
        return page + 1
    }

    private func loadAddedBooks() async throws {
        let records = try await AudiobookDAO(db: db.writer)
            .audiobookshelfRecordsAsync(serverID: serverID)
        addedBooksByRemoteID = try await Self.offMain {
            try Task.checkCancellation()
            let books = ABSLocalImportStatus.usableBooks(records: records)
            return Dictionary(books.map { ($0.remoteItemID, $0) }) { lhs, rhs in
                lhs.folderURL.absoluteString <= rhs.folderURL.absoluteString ? lhs : rhs
            }
        }
    }

    private func publishDisplayedItems(completeResult: Bool? = nil) {
        let filtered =
            selection.notAddedOnly
            ? items.filter { addedBooksByRemoteID[$0.id] == nil }
            : items
        displayedItems = filtered

        let isComplete =
            completeResult
            ?? (!trimmedSearchQuery.isEmpty || sort == .series || selection.options.count > 1)
        if isComplete {
            totalCount = filtered.count
        } else {
            totalCount = serverTotal
        }
    }

    private func publishCompleteResults(generation: Int) async throws {
        let displayed: [ABSLibraryItem]
        if selection.notAddedOnly {
            let allItems = items
            let addedIDs = Set(addedBooksByRemoteID.keys)
            displayed = try await Self.offMain {
                try ABSBrowseResultResolver.excludingAddedCancellable(
                    allItems, addedIDs: addedIDs)
            }
        } else {
            displayed = items
        }
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        displayedItems = displayed
        totalCount = displayed.count
    }

    private func republishCompleteResults(generation: Int) async throws {
        try await publishCompleteResults(generation: generation)
        guard self.generation == generation else { return }
        loadState = .loaded
    }

    private func deduplicated(_ values: [ABSLibraryItem]) -> [ABSLibraryItem] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForOwnedTask(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled { cancel() }
    }

    private func completedTask() -> Task<Void, Never> {
        Task {}
    }

    deinit {
        browseTask?.cancel()
    }
}
