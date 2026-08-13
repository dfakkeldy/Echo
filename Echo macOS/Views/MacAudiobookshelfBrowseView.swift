// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Native macOS presentation for the shared Audiobookshelf browse and import model.
/// Connection, trust, and server switching remain owned by `MacAudiobookshelfViewModel`.
struct MacAudiobookshelfBrowseView: View {
    let browseModel: ABSBrowseModel
    let onPlay: (URL) -> Void

    @State private var selectedItemID: String?
    @State private var selectedItem: ABSLibraryItem?
    @State private var isShowingFilters = false
    @State private var importWrapperTask: Task<Void, Never>?
    @State private var activeImportOperationID: UUID?

    var body: some View {
        VStack(spacing: 10) {
            controls
            Divider()
            browserContent
        }
        .searchable(text: searchBinding, prompt: Text("Search Audiobookshelf"))
        .task {
            if browseModel.loadState == .idle {
                await browseModel.load()
            }
        }
        .onChange(of: browseModel.selectedLibraryID) { _, _ in clearSelection() }
        .onDisappear { cancelOwnedWork() }
        .popover(isPresented: $isShowingFilters, arrowEdge: .bottom) {
            MacAudiobookshelfFiltersView(browseModel: browseModel)
                .frame(width: 360, height: 460)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Library", selection: selectedLibraryBinding) {
                ForEach(browseModel.libraries) { library in
                    Text(library.name).tag(Optional(library.id))
                }
            }
            .frame(maxWidth: 220)

            Picker("Sort", selection: sortBinding) {
                ForEach(ABSBrowseSort.allCases, id: \.self) { sort in
                    Text(sort.macLocalizedTitle).tag(sort)
                }
            }
            .frame(maxWidth: 190)
            .accessibilityLabel("Sort")
            .accessibilityValue(browseModel.sort.macLocalizedTitle)

            Button {
                isShowingFilters.toggle()
            } label: {
                Label {
                    if activeFilterCount == 0 {
                        Text("Filters")
                    } else {
                        Text("Filters (\(activeFilterCount))")
                    }
                } icon: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
            .accessibilityLabel("Filters")
            .accessibilityValue(String(localized: "\(activeFilterCount) active"))

            Spacer()
            resultSummary

            Button {
                Task { await browseModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(browseModel.loadState == .loading)
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        if browseModel.loadState == .loading && browseModel.libraries.isEmpty {
            ProgressView("Loading Audiobookshelf…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .failed(let message) = browseModel.loadState,
            browseModel.libraries.isEmpty
        {
            ContentUnavailableView(
                "Couldn't load",
                systemImage: "wifi.slash",
                description: Text(message))
        } else if browseModel.libraries.isEmpty {
            ContentUnavailableView(
                "No Libraries",
                systemImage: "books.vertical",
                description: Text("Audiobookshelf returned no libraries for this account."))
        } else {
            HSplitView {
                resultsPane
                    .frame(minWidth: 300, idealWidth: 340)
                detailPane
                    .frame(minWidth: 360, idealWidth: 440)
            }
        }
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            if browseModel.displayedItems.isEmpty {
                emptyOrLoadingResults
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedItemID) {
                    ForEach(browseModel.displayedItems) { item in
                        MacAudiobookshelfRow(
                            item: item,
                            isAdded: browseModel.openTarget(for: item.id) != nil
                        )
                        .tag(item.id)
                        .onAppear {
                            guard item.id == browseModel.displayedItems.last?.id else { return }
                            Task { await browseModel.loadNextPageIfNeeded() }
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: selectedItemID) { _, itemID in
                    guard let itemID,
                        let item = browseModel.displayedItems.first(where: { $0.id == itemID })
                    else { return }
                    selectedItem = item
                }
            }

            if browseModel.isLoadingNextPage {
                ProgressView("Loading more books…")
                    .controlSize(.small)
                    .padding(8)
            }

            if case .failed(let message) = browseModel.loadState,
                !browseModel.displayedItems.isEmpty
            {
                HStack {
                    Label(message, systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("Try Again") { Task { await browseModel.refresh() } }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var emptyOrLoadingResults: some View {
        if browseModel.loadState == .loading {
            ProgressView("Loading books…")
        } else if case .failed(let message) = browseModel.loadState {
            ContentUnavailableView {
                Label("Couldn't load books", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await browseModel.refresh() } }
            }
        } else if !trimmedSearchQuery.isEmpty {
            ContentUnavailableView(
                "No search results",
                systemImage: "magnifyingglass",
                description: Text("No books matched “\(trimmedSearchQuery)”."))
        } else if browseModel.selection.notAddedOnly {
            ContentUnavailableView(
                "Everything is already in Echo",
                systemImage: "checkmark.circle",
                description: Text("No remaining Audiobookshelf books match Not Added to Echo."))
        } else if !browseModel.selection.options.isEmpty {
            ContentUnavailableView(
                "No books match these filters",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Try clearing one or more filters."))
        } else {
            ContentUnavailableView(
                "No books in this library",
                systemImage: "book.closed",
                description: Text("This Audiobookshelf library does not contain any books yet."))
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedItem {
            MacAudiobookshelfDetailView(
                item: selectedItem,
                browseModel: browseModel,
                onAdd: { startImport($0, retry: false) },
                onRetry: { startImport($0, retry: true) },
                onCancel: cancelImport,
                onOpen: { book in onPlay(book.folderURL) })
        } else {
            ContentUnavailableView(
                "Select an audiobook",
                systemImage: "book.closed",
                description: Text("Choose a book to see details or add it to Echo."))
        }
    }

    @ViewBuilder
    private var resultSummary: some View {
        Group {
            if let count = browseModel.totalCount {
                if browseModel.searchResultsAreLimited {
                    Text("At least \(count) results")
                } else {
                    Text("\(count) results")
                }
            } else if browseModel.loadState == .loading {
                Text("Updating results…")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Result count")
        .accessibilityValue(resultCountAccessibilityValue)
    }

    private var selectedLibraryBinding: Binding<String?> {
        Binding(
            get: { browseModel.selectedLibraryID },
            set: { _ = browseModel.selectLibrary($0) })
    }

    private var sortBinding: Binding<ABSBrowseSort> {
        Binding(
            get: { browseModel.sort },
            set: { _ = browseModel.setSort($0) })
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { browseModel.searchQuery },
            set: { _ = browseModel.setSearchQuery($0) })
    }

    private var activeFilterCount: Int {
        browseModel.selection.options.count + (browseModel.selection.notAddedOnly ? 1 : 0)
    }

    private var trimmedSearchQuery: String {
        browseModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resultCountAccessibilityValue: String {
        guard let count = browseModel.totalCount else {
            return String(localized: "Updating results")
        }
        if browseModel.searchResultsAreLimited {
            return String(localized: "At least \(count) results")
        }
        return String(localized: "\(count) results")
    }

    private func startImport(_ item: ABSLibraryItem, retry: Bool) {
        guard importWrapperTask == nil, !browseModel.isImporting else { return }
        let operationID = UUID()
        activeImportOperationID = operationID
        importWrapperTask = Task { @MainActor in
            await Task.yield()
            guard activeImportOperationID == operationID else { return }
            if retry {
                await browseModel.retryImport(item)
            } else {
                await browseModel.add(item)
            }
            finishImport(operationID)
        }
    }

    private func finishImport(_ operationID: UUID) {
        guard activeImportOperationID == operationID else { return }
        activeImportOperationID = nil
        importWrapperTask = nil
    }

    private func cancelImport() {
        activeImportOperationID = nil
        let wrapperTask = importWrapperTask
        importWrapperTask = nil
        wrapperTask?.cancel()
        browseModel.cancelImport()
    }

    private func cancelOwnedWork() {
        cancelImport()
        browseModel.cancel()
    }

    private func clearSelection() {
        selectedItemID = nil
        selectedItem = nil
    }
}

private struct MacAudiobookshelfFiltersView: View {
    let browseModel: ABSBrowseModel

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Filters").font(.headline)
                Spacer()
                Button("Clear Filters") { _ = browseModel.clearFilters() }
                    .disabled(activeFilterCount == 0)
            }

            TextField("Search filters", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List {
                Section {
                    Toggle("Not Added to Echo", isOn: notAddedBinding)
                } footer: {
                    Text("Show only books that are not available locally in Echo.")
                }

                filterSection("Authors", options: browseModel.filterData.authors)
                filterSection("Series", options: browseModel.filterData.series)
                filterSection("Genres", options: browseModel.filterData.genres)
                filterSection("Tags", options: browseModel.filterData.tags)
            }
            .listStyle(.inset)
        }
        .padding()
    }

    @ViewBuilder
    private func filterSection(_ title: LocalizedStringKey, options: [ABSFilterOption]) -> some View
    {
        let filtered = options.filter(matchesSearch)
        if !filtered.isEmpty {
            Section(title) {
                ForEach(filtered) { option in
                    Toggle(option.label, isOn: selectionBinding(for: option))
                }
            }
        }
    }

    private func matchesSearch(_ option: ABSFilterOption) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || option.label.localizedStandardContains(query)
    }

    private func selectionBinding(for option: ABSFilterOption) -> Binding<Bool> {
        Binding(
            get: { browseModel.selection.options.contains(option) },
            set: { selected in
                guard selected != browseModel.selection.options.contains(option) else { return }
                _ = browseModel.toggleFilter(option)
            })
    }

    private var notAddedBinding: Binding<Bool> {
        Binding(
            get: { browseModel.selection.notAddedOnly },
            set: { _ = browseModel.setNotAddedOnly($0) })
    }

    private var activeFilterCount: Int {
        browseModel.selection.options.count + (browseModel.selection.notAddedOnly ? 1 : 0)
    }
}

private struct MacAudiobookshelfRow: View {
    let item: ABSLibraryItem
    let isAdded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? String(localized: "Untitled"))
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let author = item.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            if isAdded {
                Text("Added")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Added to Echo")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MacAudiobookshelfDetailView: View {
    let item: ABSLibraryItem
    let browseModel: ABSBrowseModel
    let onAdd: (ABSLibraryItem) -> Void
    let onRetry: (ABSLibraryItem) -> Void
    let onCancel: () -> Void
    let onOpen: (ABSImportedBook) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title ?? String(localized: "Untitled"))
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    if let author = item.author {
                        Text(author)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let narrator = item.media?.metadata?.narrator {
                            LabeledContent("Narrator", value: narrator)
                        }
                        if let duration = item.duration, duration > 0 {
                            LabeledContent(
                                "Duration", value: MacABSImportPresentation.duration(duration))
                        }
                        if let trackCount = item.numTracks {
                            LabeledContent("Tracks", value: "\(trackCount)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let description = item.media?.metadata?.userReadableDescription {
                    GroupBox("Description") {
                        Text(description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                importContent
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var importContent: some View {
        switch browseModel.importState(for: item.id) {
        case .ready:
            GroupBox("Add to Echo") {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        onAdd(item)
                    } label: {
                        Label("Add to Echo", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(browseModel.isImporting)

                    if browseModel.isImporting {
                        Text("Another Audiobookshelf import is in progress.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .running(let progress, let startedAt):
            GroupBox("Adding to Echo") {
                MacABSRunningImportView(
                    progress: progress,
                    startedAt: startedAt,
                    cancel: onCancel)
            }
        case .failed(let failure):
            GroupBox("Couldn't add to Echo") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Failed during \(MacABSImportPresentation.stageLabel(failure.stage))",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                    .accessibilityLabel("Import failed")
                    .accessibilityValue(MacABSImportPresentation.stageLabel(failure.stage))

                    Text(failure.message)
                    if failure.isRetryable {
                        Button("Retry") { onRetry(item) }
                            .buttonStyle(.borderedProminent)
                            .disabled(browseModel.isImporting)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .added(let book):
            GroupBox("Added to Echo") {
                HStack {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Added to Echo")
                    Spacer()
                    Button {
                        onOpen(book)
                    } label: {
                        Label("Open in Echo", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct MacABSRunningImportView: View {
    let progress: ABSImportProgress
    let startedAt: Date
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            progressContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Import progress")
                .accessibilityValue(accessibilityValue)

            if progress.stage == .downloading || progress.stage == .extracting {
                Button(role: .destructive, action: cancel) {
                    Label("Cancel Import", systemImage: "xmark.circle")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MacABSImportPresentation.stageLabel(progress.stage))
                .font(.headline)

            if let total = progress.totalUnits, total > 0 {
                ProgressView(
                    value: min(max(Double(progress.completedUnits), 0), Double(total)),
                    total: Double(total))
            } else {
                ProgressView()
            }

            if progress.stage == .downloading || progress.stage == .extracting {
                Text(MacABSImportPresentation.progressLabel(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(
                    "Elapsed \(MacABSImportPresentation.elapsed(from: startedAt, to: context.date))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityValue: String {
        let stage = MacABSImportPresentation.stageLabel(progress.stage)
        guard progress.stage == .downloading || progress.stage == .extracting else {
            return stage
        }
        return "\(stage), \(MacABSImportPresentation.progressLabel(progress))"
    }
}

private enum MacABSImportPresentation {
    static func progressLabel(_ progress: ABSImportProgress) -> String {
        switch progress.unit {
        case .bytes:
            return byteProgressLabel(
                completed: progress.completedUnits,
                total: progress.totalUnits)
        case .files:
            return countProgressLabel(
                completed: progress.completedUnits,
                total: progress.totalUnits,
                singular: String(localized: "file"),
                plural: String(localized: "files"))
        case .units:
            return countProgressLabel(
                completed: progress.completedUnits,
                total: progress.totalUnits,
                singular: String(localized: "unit"),
                plural: String(localized: "units"))
        }
    }

    static func stageLabel(_ stage: ABSImportStage) -> String {
        switch stage {
        case .downloading: return String(localized: "Downloading")
        case .extracting: return String(localized: "Extracting")
        case .validating: return String(localized: "Validating")
        case .addingToEcho: return String(localized: "Adding to Echo")
        case .added: return String(localized: "Added")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func elapsed(from startedAt: Date, to now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        }
        return "\(minutes):\(twoDigits(seconds))"
    }

    private static func byteProgressLabel(completed: Int64, total: Int64?) -> String {
        let safeCompleted = max(0, completed)
        let completedText = ByteCountFormatter.string(
            fromByteCount: safeCompleted,
            countStyle: .file)
        guard let total, total > 0 else { return completedText }
        let percent = min(100, max(0, Int((Double(safeCompleted) / Double(total) * 100).rounded())))
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return String(localized: "\(percent)% · \(completedText) of \(totalText)")
    }

    private static func countProgressLabel(
        completed: Int64,
        total: Int64?,
        singular: String,
        plural: String
    ) -> String {
        let safeCompleted = max(0, completed)
        guard let total, total > 0 else {
            let unit = safeCompleted == 1 ? singular : plural
            return String(localized: "\(safeCompleted) \(unit)")
        }
        let percent = min(100, max(0, Int((Double(safeCompleted) / Double(total) * 100).rounded())))
        return String(localized: "\(percent)% · \(safeCompleted) of \(total) \(plural)")
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

extension ABSBrowseSort {
    fileprivate var macLocalizedTitle: String {
        switch self {
        case .newestAdded: return String(localized: "Newest Added")
        case .title: return String(localized: "Title")
        case .author: return String(localized: "Author")
        case .series: return String(localized: "Series")
        case .publicationYear: return String(localized: "Publication Year")
        }
    }
}
