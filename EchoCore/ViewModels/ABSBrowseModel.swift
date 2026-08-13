// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

// ABS library items are immutable decoded value graphs. This conformance lets the
// browse model move complete-result set algebra and sorting off the UI actor.
extension ABSLibraryItem: @unchecked Sendable {}

@MainActor @Observable
final class ABSBrowseModel {
    typealias NotAddedProjection =
        @Sendable ([ABSLibraryItem], Set<String>) async throws -> [ABSLibraryItem]

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum ResultCompleteness: Equatable {
        case empty
        case partial
        case complete
    }

    enum ImportState: Equatable {
        case ready
        case running(ABSImportProgress, startedAt: Date)
        case failed(ABSImportFailure)
        case added(ABSImportedBook)
    }

    private static let sortPreferenceKey = "absBrowseSort"
    private static let pageSize = 100
    private static let searchLimit = 10_000
    private static let maximumConcurrentFilterQueries = 4

    @ObservationIgnored private let service: AudiobookshelfService
    @ObservationIgnored private let db: DatabaseService
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let notAddedProjection: NotAddedProjection
    @ObservationIgnored private let importService: ABSImportService
    @ObservationIgnored private let afterAddedBooksLoad: @MainActor @Sendable () async -> Void
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<ABSImportedBook, Error>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var projectionGeneration = 0
    @ObservationIgnored private var importSuccessRevision = 0
    @ObservationIgnored private var importSuccessRevisionsByItemID: [String: Int] = [:]
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
    private(set) var resultCompleteness: ResultCompleteness = .empty
    var isLoadingNextPage = false
    private(set) var addedBooksByRemoteID: [String: ABSImportedBook] = [:]
    private(set) var importStates: [String: ImportState] = [:]
    private(set) var activeImportItemID: String?

    var isImporting: Bool { activeImportItemID != nil }

    init(
        service: AudiobookshelfService,
        db: DatabaseService,
        serverID: String,
        debounce: Duration = .milliseconds(300),
        preferences: UserDefaults = .standard,
        notAddedProjection: NotAddedProjection? = nil,
        importService: ABSImportService? = nil,
        afterAddedBooksLoad: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.service = service
        self.db = db
        self.serverID = serverID
        self.debounce = debounce
        self.preferences = preferences
        self.importService =
            importService ?? ABSImportService(service: service, db: db, serverID: serverID)
        self.afterAddedBooksLoad = afterAddedBooksLoad
        self.notAddedProjection =
            notAddedProjection
            ?? { allItems, addedIDs in
                try await Self.offMain {
                    try ABSBrowseResultResolver.excludingAddedCancellable(
                        allItems, addedIDs: addedIDs)
                }
            }
        sort =
            preferences.string(forKey: Self.sortPreferenceKey)
            .flatMap(ABSBrowseSort.init(rawValue:)) ?? .newestAdded
    }

    func load() async {
        let task = replaceTask(clearResults: true) { model, generation in
            try await model.loadRoot(generation: generation)
        }
        let activeGeneration = generation
        await waitForOwnedTask(task, generation: activeGeneration)
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
        invalidateProjection()
        selection.notAddedOnly = enabled

        if loadState == .loading, let browseTask {
            return browseTask
        }
        if enabled, resultCompleteness == .partial {
            return startSelectedLibraryLoad(clearResults: false, reloadFilterData: false)
        }
        if resultCompleteness == .complete {
            return startProjection()
        }
        if !enabled, resultCompleteness == .partial {
            publishDisplayedItems(completeResult: false)
            return completedTask()
        }
        displayedItems = []
        totalCount = nil
        return completedTask()
    }

    @discardableResult
    func clearFilters() -> Task<Void, Never> {
        let hadMetadataFilters = !selection.options.isEmpty
        let hadNotAddedFilter = selection.notAddedOnly
        if hadNotAddedFilter { invalidateProjection() }
        selection = ABSFilterSelection()
        if hadMetadataFilters {
            return startSelectedLibraryLoad(clearResults: true, reloadFilterData: false)
        } else if hadNotAddedFilter, loadState == .loading, let browseTask {
            return browseTask
        } else if hadNotAddedFilter, resultCompleteness == .complete {
            return startProjection()
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
        let activeGeneration = generation
        await waitForOwnedTask(task, generation: activeGeneration)
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
        await waitForOwnedTask(task, generation: activeGeneration)
    }

    func cancel() {
        browseTask?.cancel()
        browseTask = nil
        invalidateProjection()
        generation += 1
        isLoadingNextPage = false
        loadState = .idle
    }

    func importState(for itemID: String) -> ImportState {
        if let state = importStates[itemID] { return state }
        if let book = addedBooksByRemoteID[itemID] { return .added(book) }
        return .ready
    }

    func add(_ item: ABSLibraryItem) async {
        guard activeImportItemID == nil, addedBooksByRemoteID[item.id] == nil else { return }

        let startedAt = Date()
        let initialProgress = ABSImportProgress(
            stage: .downloading, completedUnits: 0, totalUnits: nil)
        activeImportItemID = item.id
        importStates[item.id] = .running(initialProgress, startedAt: startedAt)

        let task = Task<ABSImportedBook, Error> { [importService, weak self] in
            try await importService.prepareLocalFolder(for: item) { [weak self] progress in
                self?.applyImportProgress(progress, for: item.id, startedAt: startedAt)
            }
        }
        importTask = task
        defer {
            if activeImportItemID == item.id {
                importTask = nil
                activeImportItemID = nil
            }
        }

        do {
            let book = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard activeImportItemID == item.id else { return }
            importSuccessRevision += 1
            importSuccessRevisionsByItemID[item.id] = importSuccessRevision
            addedBooksByRemoteID[item.id] = book
            importStates[item.id] = .added(book)
            if selection.notAddedOnly {
                invalidateProjection()
                displayedItems.removeAll { $0.id == item.id }
                totalCount = displayedItems.count
            }
        } catch is CancellationError {
            guard activeImportItemID == item.id else { return }
            importStates[item.id] = .failed(cancellationFailure(for: item.id))
        } catch let failure as ABSImportFailure {
            guard activeImportItemID == item.id else { return }
            importStates[item.id] = .failed(failure)
        } catch {
            guard activeImportItemID == item.id else { return }
            importStates[item.id] = .failed(unexpectedImportFailure(for: item.id))
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    func retryImport(_ item: ABSLibraryItem) async {
        guard case .failed(let failure) = importState(for: item.id), failure.isRetryable else {
            return
        }
        await add(item)
    }

    func openTarget(for itemID: String) -> ABSImportedBook? {
        if case .added(let book) = importState(for: itemID) { return book }
        return nil
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
        let provenanceRevision = importSuccessRevision
        let addedBooks = try await loadAddedBooks()
        await afterAddedBooksLoad()
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        publishAddedBooks(addedBooks, snapshotRevision: provenanceRevision)

        guard selectedLibraryID != nil else {
            filterData = .empty
            items = []
            displayedItems = []
            totalCount = 0
            nextPage = nil
            searchResultsAreLimited = false
            resultCompleteness = .complete
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
        let provenanceRevision = importSuccessRevision
        let addedBooks = try await loadAddedBooks()
        await afterAddedBooksLoad()
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        publishAddedBooks(addedBooks, snapshotRevision: provenanceRevision)
        guard selectedLibraryID != nil else {
            filterData = .empty
            items = []
            displayedItems = []
            totalCount = 0
            nextPage = nil
            searchResultsAreLimited = false
            resultCompleteness = .complete
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
        invalidateProjection()
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
            resultCompleteness = .empty
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
            resultCompleteness = .complete
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
            resultCompleteness = .complete
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
            resultCompleteness = .complete
            try await publishCompleteResults(generation: generation)
            loadState = .loaded
            return
        }

        let response = try await service.items(libraryID: libraryID, query: query)
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        if selection.notAddedOnly {
            let allItems = try await service.allItems(libraryID: libraryID, query: query)
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            let selectedSort = sort
            items = try await Self.offMain {
                try ABSBrowseResultResolver.sortedCancellable(allItems, by: selectedSort)
            }
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            serverTotal = items.count
            nextPage = nil
            resultCompleteness = .complete
            try await publishCompleteResults(generation: generation)
            loadState = .loaded
            return
        }
        items = response.results
        serverTotal = response.total
        nextPage = nextPage(after: response, requestedPage: 0, requestedLimit: Self.pageSize)
        resultCompleteness = nextPage == nil ? .complete : .partial
        if resultCompleteness == .complete {
            try await publishCompleteResults(generation: generation)
        } else {
            publishDisplayedItems(completeResult: false)
        }
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
        resultCompleteness = .complete
        searchResultsAreLimited = fetchedSearchResults.count == Self.searchLimit
        try await publishCompleteResults(generation: generation)
        loadState = .loaded
    }

    private func loadCompleteOptionResults(
        libraryID: String,
        options: [ABSFilterOption]
    ) async throws -> [ABSFilterOption: [ABSLibraryItem]] {
        let selectedSort = sort
        let pageSize = Self.pageSize
        var iterator = options.makeIterator()
        return try await withThrowingTaskGroup(
            of: (ABSFilterOption, [ABSLibraryItem]).self,
            returning: [ABSFilterOption: [ABSLibraryItem]].self
        ) { group in
            func addNext() {
                guard let option = iterator.next() else { return }
                group.addTask { [service, selectedSort] in
                    var query = ABSLibraryItemsQuery(
                        limit: pageSize, sort: selectedSort)
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

            if selection.notAddedOnly {
                query.page = 0
                let allItems = try await service.allItems(libraryID: libraryID, query: query)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let selectedSort = sort
                items = try await Self.offMain {
                    try ABSBrowseResultResolver.sortedCancellable(allItems, by: selectedSort)
                }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                serverTotal = items.count
                nextPage = nil
                resultCompleteness = .complete
                try await publishCompleteResults(generation: generation)
                loadState = .loaded
                return
            }

            items.append(contentsOf: response.results)
            items = deduplicated(items)
            serverTotal = response.total ?? serverTotal
            nextPage = nextPage(
                after: response, requestedPage: page, requestedLimit: Self.pageSize)
            resultCompleteness = nextPage == nil ? .complete : .partial
            if resultCompleteness == .complete {
                try await publishCompleteResults(generation: generation)
            } else {
                publishDisplayedItems(completeResult: false)
            }
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

    private func loadAddedBooks() async throws -> [String: ABSImportedBook] {
        let records = try await AudiobookDAO(db: db.writer)
            .audiobookshelfRecordsAsync(serverID: serverID)
        try Task.checkCancellation()
        return try await Self.offMain {
            try Task.checkCancellation()
            let books = ABSLocalImportStatus.usableBooks(records: records)
            return Dictionary(books.map { ($0.remoteItemID, $0) }) { lhs, rhs in
                lhs.folderURL.absoluteString <= rhs.folderURL.absoluteString ? lhs : rhs
            }
        }
    }

    private func publishAddedBooks(
        _ loadedBooks: [String: ABSImportedBook],
        snapshotRevision: Int
    ) {
        var reconciledBooks = loadedBooks
        let addedStates = importStates.compactMap { itemID, state -> (String, ABSImportedBook)? in
            guard case .added(let book) = state else { return nil }
            return (itemID, book)
        }
        for (itemID, retainedBook) in addedStates {
            if importSuccessRevisionsByItemID[itemID, default: 0] > snapshotRevision {
                reconciledBooks[itemID] = retainedBook
            } else if let loadedBook = loadedBooks[itemID] {
                importStates[itemID] = .added(loadedBook)
            } else {
                importStates.removeValue(forKey: itemID)
                importSuccessRevisionsByItemID.removeValue(forKey: itemID)
            }
        }
        addedBooksByRemoteID = reconciledBooks
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
        while true {
            let activeProjectionGeneration = projectionGeneration
            let notAddedOnly = selection.notAddedOnly
            let allItems = items
            let addedIDs = Set(addedBooksByRemoteID.keys)
            let displayed: [ABSLibraryItem]
            if notAddedOnly {
                displayed = try await notAddedProjection(allItems, addedIDs)
            } else {
                displayed = allItems
            }
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            guard projectionGeneration == activeProjectionGeneration else { continue }
            displayedItems = displayed
            totalCount = displayed.count
            return
        }
    }

    private func startProjection() -> Task<Void, Never> {
        let activeGeneration = generation
        let activeProjectionGeneration = projectionGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.projectionGeneration == activeProjectionGeneration {
                    self.projectionTask = nil
                }
            }
            do {
                try await self.publishCompleteResults(generation: activeGeneration)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        projectionTask = task
        return task
    }

    private func invalidateProjection() {
        projectionTask?.cancel()
        projectionTask = nil
        projectionGeneration += 1
    }

    private func deduplicated(_ values: [ABSLibraryItem]) -> [ABSLibraryItem] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForOwnedTask(_ task: Task<Void, Never>, generation: Int) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled { cancel(generation: generation) }
    }

    private func cancel(generation canceledGeneration: Int) {
        guard generation == canceledGeneration else { return }
        cancel()
    }

    private func completedTask() -> Task<Void, Never> {
        Task {}
    }

    private func applyImportProgress(
        _ progress: ABSImportProgress,
        for itemID: String,
        startedAt: Date
    ) {
        guard activeImportItemID == itemID else { return }
        importStates[itemID] = .running(progress, startedAt: startedAt)
    }

    private func cancellationFailure(for itemID: String) -> ABSImportFailure {
        let stage: ABSImportStage
        if case .running(let progress, _) = importStates[itemID] {
            stage = progress.stage
        } else {
            stage = .downloading
        }
        return ABSImportFailure(
            stage: stage,
            message: String(localized: "The import was cancelled. You can retry when ready."),
            isRetryable: true)
    }

    private func unexpectedImportFailure(for itemID: String) -> ABSImportFailure {
        let stage: ABSImportStage
        if case .running(let progress, _) = importStates[itemID] {
            stage = progress.stage
        } else {
            stage = .downloading
        }
        return ABSImportFailure(
            stage: stage,
            message: String(localized: "Echo could not add this audiobook. Try again."),
            isRetryable: true)
    }

    deinit {
        browseTask?.cancel()
        projectionTask?.cancel()
        importTask?.cancel()
    }
}
