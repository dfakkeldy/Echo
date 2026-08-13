// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

struct ABSBrowseView: View {
    let browseModel: ABSBrowseModel
    let onOpen: (ABSImportedBook) -> Void

    @Environment(PlayerModel.self) private var playerModel
    @Environment(\.dismiss) private var dismiss
    @State private var presentedSheet: SheetDestination?

    private enum SheetDestination: String, Identifiable {
        case filters

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            rootContent
                .navigationTitle("Audiobookshelf")
                .searchable(
                    text: searchBinding,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search Audiobookshelf")
                )
                .toolbar { toolbarContent }
                .task { await browseModel.load() }
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .filters:
                ABSFiltersView(browseModel: browseModel)
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch browseModel.loadState {
        case .loading where browseModel.libraries.isEmpty:
            ProgressView("Loading Audiobookshelf…")
        case .failed(let message) where browseModel.libraries.isEmpty:
            ContentUnavailableView(
                "Couldn't load", systemImage: "wifi.slash", description: Text(message))
        default:
            libraryList
        }
    }

    private var libraryList: some View {
        List {
            if browseModel.libraries.count > 1 {
                Section {
                    Picker("Library", selection: selectedLibraryBinding) {
                        ForEach(browseModel.libraries) { library in
                            Text(library.name).tag(Optional(library.id))
                        }
                    }
                }
            }

            if browseModel.libraries.isEmpty {
                ContentUnavailableView(
                    "No Libraries", systemImage: "books.vertical",
                    description: Text("Audiobookshelf returned no libraries for this account.")
                )
                .listRowSeparator(.hidden)
            } else {
                resultSummary

                if browseModel.displayedItems.isEmpty {
                    if browseModel.loadState == .loading {
                        ProgressView("Loading books…")
                    } else if case .failed(let message) = browseModel.loadState {
                        ContentUnavailableView(
                            "Couldn't load books", systemImage: "wifi.slash",
                            description: Text(message))
                        Button("Try Again") { Task { await browseModel.refresh() } }
                    } else {
                        emptyResultsView
                    }
                } else {
                    ForEach(browseModel.displayedItems) { item in
                        NavigationLink {
                            ABSItemDetailView(
                                item: item,
                                browseModel: browseModel,
                                service: playerModel.makeAudiobookshelfService(),
                                onOpen: onOpen)
                        } label: {
                            ABSItemRow(
                                item: item,
                                isAdded: browseModel.openTarget(for: item.id) != nil,
                                service: playerModel.makeAudiobookshelfService())
                        }
                        .onAppear {
                            guard item.id == browseModel.displayedItems.last?.id else { return }
                            Task { await browseModel.loadNextPageIfNeeded() }
                        }
                    }

                    if browseModel.isLoadingNextPage {
                        ProgressView("Loading more books…")
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    }

                    if case .failed(let message) = browseModel.loadState {
                        ContentUnavailableView(
                            "Couldn't refresh books", systemImage: "wifi.slash",
                            description: Text(message))
                        Button("Try Again") { Task { await browseModel.refresh() } }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await browseModel.refresh() }
    }

    private var resultSummary: some View {
        Group {
            if let count = browseModel.totalCount {
                if browseModel.searchResultsAreLimited {
                    Text("At least \(count) results · search limited by Audiobookshelf")
                } else {
                    Text("\(count) results")
                }
            } else if browseModel.loadState == .loading {
                Text("Updating results…")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Result count")
    }

    @ViewBuilder
    private var emptyResultsView: some View {
        if !trimmedSearchQuery.isEmpty {
            ContentUnavailableView(
                "No search results", systemImage: "magnifyingglass",
                description: Text("No books matched “\(trimmedSearchQuery)”."))
        } else if browseModel.selection.notAddedOnly {
            ContentUnavailableView(
                "Everything is already in Echo", systemImage: "checkmark.circle",
                description: Text("No remaining Audiobookshelf books match Not Added to Echo."))
        } else if !browseModel.selection.options.isEmpty {
            ContentUnavailableView(
                "No books match these filters", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Try clearing one or more filters."))
        } else {
            ContentUnavailableView(
                "No books in this library", systemImage: "book.closed",
                description: Text("This Audiobookshelf library does not contain any books yet."))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(ABSBrowseSort.allCases, id: \.self) { sort in
                    Button {
                        _ = browseModel.setSort(sort)
                    } label: {
                        if browseModel.sort == sort {
                            Label(sort.localizedTitle, systemImage: "checkmark")
                        } else {
                            Text(sort.localizedTitle)
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort")
            .accessibilityValue(browseModel.sort.localizedTitle)

            Button {
                presentedSheet = .filters
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
        }
    }

    private var selectedLibraryBinding: Binding<String?> {
        Binding(
            get: { browseModel.selectedLibraryID },
            set: { _ = browseModel.selectLibrary($0) })
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
}

private struct ABSFiltersView: View {
    let browseModel: ABSBrowseModel

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search filters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear Filters") { _ = browseModel.clearFilters() }
                        .disabled(activeFilterCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

private struct ABSItemRow: View {
    let item: ABSLibraryItem
    let isAdded: Bool
    let service: AudiobookshelfService?

    var body: some View {
        HStack(spacing: 12) {
            ABSAuthenticatedCoverImage(
                service: service,
                itemID: item.id,
                hasCover: ABSBrowsePresentation.shouldLoadCover(for: item),
                contentMode: .fill,
                placeholderFont: nil
            )
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? String(localized: "Untitled"))
                    .font(.body)
                    .lineLimit(2)
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
    }
}

private struct ABSItemDetailView: View {
    let item: ABSLibraryItem
    let browseModel: ABSBrowseModel
    let service: AudiobookshelfService?
    let onOpen: (ABSImportedBook) -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    ABSAuthenticatedCoverImage(
                        service: service,
                        itemID: item.id,
                        hasCover: ABSBrowsePresentation.shouldLoadCover(for: item),
                        contentMode: .fit,
                        placeholderFont: .largeTitle
                    )
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(.rect(cornerRadius: 8))
                    Spacer()
                }
            }

            Section {
                LabeledContent("Title", value: item.title ?? String(localized: "Untitled"))
                if let author = item.author { LabeledContent("Author", value: author) }
                if let narrator = item.media?.metadata?.narrator {
                    LabeledContent("Narrator", value: narrator)
                }
                if let duration = ABSBrowsePresentation.displayDuration(for: item) {
                    LabeledContent("Duration", value: ABSImportPresentation.duration(duration))
                }
                if let trackCount = item.numTracks {
                    LabeledContent("Tracks", value: "\(trackCount)")
                }
            }

            if let description = ABSBrowsePresentation.displayDescription(for: item) {
                Section("Description") { Text(description).font(.callout) }
            }

            importSection
        }
        .navigationTitle(item.title ?? String(localized: "Untitled"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var importSection: some View {
        switch browseModel.importState(for: item.id) {
        case .ready:
            Section {
                Button {
                    Task { await addWithBackgroundGrace() }
                } label: {
                    Label("Add to Echo", systemImage: "arrow.down.circle")
                }
                .disabled(browseModel.isImporting)

                if browseModel.isImporting {
                    Text("Another Audiobookshelf import is in progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .running(let progress, let startedAt):
            Section {
                ABSRunningImportView(
                    progress: progress,
                    startedAt: startedAt,
                    cancel: browseModel.cancelImport)
            }
        case .failed(let failure):
            Section {
                Label(
                    "Failed during \(ABSImportPresentation.stageLabel(failure.stage))",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
                .accessibilityLabel("Import failed")
                .accessibilityValue(ABSImportPresentation.stageLabel(failure.stage))
                Text(failure.message)

                if failure.isRetryable {
                    Button("Retry") { Task { await retryWithBackgroundGrace() } }
                }
            } header: {
                Text("Couldn't add to Echo")
            }
        case .added(let book):
            Section {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Added to Echo")
                Button {
                    onOpen(book)
                } label: {
                    Label("Open in Echo", systemImage: "play.circle")
                }
            }
        }
    }

    private func addWithBackgroundGrace() async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "abs-import")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        await browseModel.add(item)
    }

    private func retryWithBackgroundGrace() async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "abs-import")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        await browseModel.retryImport(item)
    }
}

private struct ABSRunningImportView: View {
    let progress: ABSImportProgress
    let startedAt: Date
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ABSImportPresentation.stageLabel(progress.stage))
                .font(.headline)

            if let total = progress.totalUnits, total > 0 {
                ProgressView(
                    value: min(max(Double(progress.completedUnits), 0), Double(total)),
                    total: Double(total))
            } else {
                ProgressView()
            }

            if progress.stage == .downloading {
                Text(
                    ABSImportPresentation.progressLabel(
                        completed: progress.completedUnits,
                        total: progress.totalUnits)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if progress.stage == .extracting {
                Text(
                    ABSImportPresentation.extractionProgressLabel(
                        completed: progress.completedUnits,
                        total: progress.totalUnits)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Elapsed \(ABSImportPresentation.elapsed(from: startedAt, to: context.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if progress.stage == .downloading || progress.stage == .extracting {
                Button(role: .destructive, action: cancel) {
                    Label("Cancel Import", systemImage: "xmark.circle")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Import progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let stage = ABSImportPresentation.stageLabel(progress.stage)
        guard progress.stage == .downloading || progress.stage == .extracting else {
            return stage
        }
        let progressText =
            progress.stage == .downloading
            ? ABSImportPresentation.progressLabel(
                completed: progress.completedUnits, total: progress.totalUnits)
            : ABSImportPresentation.extractionProgressLabel(
                completed: progress.completedUnits, total: progress.totalUnits)
        return "\(stage), \(progressText)"
    }
}

enum ABSImportPresentation {
    static func progressLabel(completed: Int64, total: Int64?) -> String {
        let safeCompleted = max(0, completed)
        let completedText = ByteCountFormatter.string(
            fromByteCount: safeCompleted, countStyle: .file)
        guard let total, total > 0 else { return completedText }
        let percent = min(100, max(0, Int((Double(safeCompleted) / Double(total) * 100).rounded())))
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return String(localized: "\(percent)% · \(completedText) of \(totalText)")
    }

    static func stageLabel(_ stage: ABSImportStage) -> String {
        switch stage {
        case .downloading: String(localized: "Downloading")
        case .extracting: String(localized: "Extracting")
        case .validating: String(localized: "Validating")
        case .addingToEcho: String(localized: "Adding to Echo")
        case .added: String(localized: "Added")
        }
    }

    static func extractionProgressLabel(completed: Int64, total: Int64?) -> String {
        let safeCompleted = max(0, completed)
        guard let total, total > 0 else { return "\(safeCompleted)" }
        let percent = min(100, max(0, Int((Double(safeCompleted) / Double(total) * 100).rounded())))
        return String(localized: "\(percent)% · \(safeCompleted) of \(total) units")
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

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

extension ABSBrowseSort {
    fileprivate var localizedTitle: String {
        switch self {
        case .newestAdded: String(localized: "Newest Added")
        case .title: String(localized: "Title")
        case .author: String(localized: "Author")
        case .series: String(localized: "Series")
        case .publicationYear: String(localized: "Publication Year")
        }
    }
}

private struct ABSAuthenticatedCoverImage: View {
    let service: AudiobookshelfService?
    let itemID: String
    let hasCover: Bool
    let contentMode: ContentMode
    let placeholderFont: Font?

    @State private var imageData: Data?

    var body: some View {
        Group {
            #if canImport(UIKit)
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .accessibilityLabel(Text("Cover"))
                } else {
                    placeholder
                }
            #elseif canImport(AppKit)
                if let imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .accessibilityLabel(Text("Cover"))
                } else {
                    placeholder
                }
            #else
                placeholder
            #endif
        }
        .task(id: itemID) {
            await loadCover()
        }
    }

    private var placeholder: some View {
        Image(systemName: "book.closed")
            .font(placeholderFont)
            .foregroundStyle(.secondary)
    }

    private func loadCover() async {
        guard hasCover, let service else {
            imageData = nil
            return
        }
        do {
            imageData = try await service.coverImageData(itemID: itemID)
        } catch is CancellationError {
            // Superseded by row/detail teardown.
        } catch {
            imageData = nil
        }
    }
}

enum ABSBrowsePresentation {
    static func shouldLoadCover(for item: ABSLibraryItem) -> Bool {
        item.coverPath?.isEmpty == false
    }

    static func displayDuration(for item: ABSLibraryItem) -> Double? {
        item.duration.flatMap { $0 > 0 ? $0 : nil }
    }

    static func displayDescription(for item: ABSLibraryItem) -> String? {
        item.media?.metadata?.userReadableDescription
    }
}
