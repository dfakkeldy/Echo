// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ABSBrowseView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var libraries: [ABSLibrary] = []
    @State private var selectedLibrary: ABSLibrary?
    @State private var items: [ABSLibraryItem] = []
    @State private var isLoading = false
    @State private var isLoadingItems = false
    @State private var isSearching = false
    @State private var browseErrorMessage: String?
    @State private var searchErrorMessage: String?
    @State private var searchQuery = ""
    @State private var searchResults: [ABSLibraryItem]? = nil

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if let browseErrorMessage, libraries.isEmpty {
                    ContentUnavailableView(
                        "Couldn't load", systemImage: "wifi.slash",
                        description: Text(browseErrorMessage))
                } else {
                    List {
                        if libraries.count > 1 {
                            Picker("Library", selection: $selectedLibrary) {
                                ForEach(libraries) { lib in Text(lib.name).tag(Optional(lib)) }
                            }
                        }
                        if libraries.isEmpty {
                            ContentUnavailableView("No Libraries", systemImage: "books.vertical",
                                description: Text(
                                    "Audiobookshelf returned no libraries for this account."
                                )
                            )
                            .listRowSeparator(.hidden)
                        } else {
                            if let searchErrorMessage {
                                ContentUnavailableView(
                                    "Couldn't search", systemImage: "magnifyingglass",
                                    description: Text(searchErrorMessage))
                                .listRowSeparator(.hidden)
                            }

                            if displayedItems.isEmpty {
                                if isLoadingItems {
                                    ProgressView("Loading books...")
                                } else if isSearching {
                                    ProgressView("Searching...")
                                } else if let browseErrorMessage {
                                    ContentUnavailableView(
                                        "Couldn't load books", systemImage: "wifi.slash",
                                        description: Text(browseErrorMessage))
                                    .listRowSeparator(.hidden)
                                } else if isShowingSearchResults, searchErrorMessage == nil {
                                    ContentUnavailableView(
                                        "No Results", systemImage: "magnifyingglass",
                                        description: Text(
                                            "No books matched \"\(trimmedSearchQuery)\"."
                                        )
                                    )
                                    .listRowSeparator(.hidden)
                                } else if searchErrorMessage == nil {
                                    ContentUnavailableView(
                                        "No Books", systemImage: "book.closed",
                                        description: Text(
                                            "This Audiobookshelf library does not contain any books yet."
                                        )
                                    )
                                    .listRowSeparator(.hidden)
                                }
                            } else {
                                ForEach(displayedItems) { item in
                                    NavigationLink {
                                        ABSItemDetailView(item: item, onImported: { dismiss() })
                                    } label: {
                                        ABSItemRow(
                                            item: item,
                                            service: model.makeAudiobookshelfService())
                                    }
                                }

                                if isLoadingItems {
                                    ProgressView("Loading books...")
                                }
                                if isSearching {
                                    ProgressView("Searching...")
                                }
                                if let browseErrorMessage {
                                    ContentUnavailableView(
                                        "Couldn't load books", systemImage: "wifi.slash",
                                        description: Text(browseErrorMessage))
                                    .listRowSeparator(.hidden)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Audiobookshelf")
            .searchable(text: $searchQuery)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task { await loadLibraries() }
            // `.task(id:)` AUTO-CANCELS the prior item load when the selection changes —
            // prevents a slow older library's response from overwriting a newer one.
            // Do NOT replace with `.onChange { Task {} }`.
            .task(id: selectedLibrary?.id) {
                await loadItems()
                await runSearch()
            }
            .task(id: searchQuery) { await runSearch() }
        }
    }

    private func runSearch() async {
        let q = trimmedSearchQuery
        guard !q.isEmpty else {
            searchResults = nil
            searchErrorMessage = nil
            isSearching = false
            return
        }
        guard let service = model.makeAudiobookshelfService(), let lib = selectedLibrary else {
            isSearching = false
            return
        }
        do {
            isSearching = true
            defer { isSearching = false }
            try await Task.sleep(for: .milliseconds(300))  // debounce keystrokes
            try Task.checkCancellation()
            let results = try await service.search(libraryID: lib.id, query: q)
            try Task.checkCancellation()
            searchResults = results
            searchErrorMessage = nil
        } catch is CancellationError {
            // superseded by a newer keystroke — ignore
        } catch {
            searchResults = nil
            searchErrorMessage = error.localizedDescription
        }
    }

    private func loadLibraries() async {
        guard let service = model.makeAudiobookshelfService() else {
            browseErrorMessage = "No server connected."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            libraries = try await service.libraries()
            selectedLibrary = libraries.first
            browseErrorMessage = nil
        } catch {
            browseErrorMessage = error.localizedDescription
        }
    }

    private func loadItems() async {
        guard let service = model.makeAudiobookshelfService(), let lib = selectedLibrary else {
            items = []
            return
        }
        do {
            isLoadingItems = true
            defer { isLoadingItems = false }
            items = []
            browseErrorMessage = nil
            _ = try await service.pagedItems(libraryID: lib.id) { pageItems in
                try Task.checkCancellation()
                items.append(contentsOf: pageItems)
            }
            try Task.checkCancellation()  // bail if the selection already moved on
            browseErrorMessage = nil
        } catch is CancellationError {
            // superseded by a newer selection — ignore
        } catch {
            browseErrorMessage = error.localizedDescription
        }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedItems: [ABSLibraryItem] {
        searchResults ?? items
    }

    private var isShowingSearchResults: Bool {
        !trimmedSearchQuery.isEmpty
    }
}

private struct ABSItemRow: View {
    let item: ABSLibraryItem
    let service: AudiobookshelfService?

    var body: some View {
        HStack(spacing: 12) {
            ABSAuthenticatedCoverImage(
                service: service,
                itemID: item.id,
                hasCover: ABSBrowsePresentation.shouldLoadCover(for: item),
                contentMode: .fill,
                placeholderFont: nil)
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "Untitled").font(.body).lineLimit(2)
                if let author = item.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct ABSItemDetailView: View {
    let item: ABSLibraryItem
    let onImported: () -> Void
    @Environment(PlayerModel.self) private var model
    @State private var importTask: Task<Void, Never>?
    @State private var importStartedAt: Date?
    @State private var isCancelingImport = false
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    ABSAuthenticatedCoverImage(
                        service: model.makeAudiobookshelfService(),
                        itemID: item.id,
                        hasCover: ABSBrowsePresentation.shouldLoadCover(for: item),
                        contentMode: .fit,
                        placeholderFont: .largeTitle)
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(.rect(cornerRadius: 8))
                    Spacer()
                }
            }
            Section {
                LabeledContent("Title", value: item.title ?? "Untitled")
                if let author = item.author { LabeledContent("Author", value: author) }
                if let narrator = item.media?.metadata?.narrator {
                    LabeledContent("Narrator", value: narrator)
                }
                if let duration = ABSBrowsePresentation.displayDuration(for: item) {
                    LabeledContent("Duration", value: Self.formatted(duration))
                }
                if let n = item.numTracks { LabeledContent("Tracks", value: "\(n)") }
            }
            if let description = ABSBrowsePresentation.displayDescription(for: item) {
                Section("Description") { Text(description).font(.callout) }
            }
            Section {
                if let importStartedAt {
                    importProgressView(startedAt: importStartedAt)
                } else {
                    Button {
                        beginImport()
                    } label: {
                        Label("Add to Library", systemImage: "arrow.down.circle")
                    }
                }
            }
            if let importError {
                Section {
                    Text(importError).foregroundStyle(.red)
                } header: {
                    Text("Couldn't add")
                }
            }
        }
        .navigationTitle(item.title ?? "Untitled")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func importProgressView(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCancelingImport ? "Canceling…" : "Downloading…")
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("Elapsed \(Self.formattedElapsed(from: startedAt, to: context.date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Large Audiobookshelf books may take a while. If the connection stalls, cancel and retry.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                cancelImport()
            } label: {
                Label("Cancel Import", systemImage: "xmark.circle")
            }
            .disabled(isCancelingImport)
        }
    }

    private func beginImport() {
        guard importTask == nil else { return }
        importError = nil
        isCancelingImport = false
        importStartedAt = Date()
        importTask = Task { await importBook() }
    }

    private func cancelImport() {
        isCancelingImport = true
        importTask?.cancel()
    }

    private func importBook() async {
        defer {
            importTask = nil
            importStartedAt = nil
            isCancelingImport = false
        }
        do {
            try await model.addFromAudiobookshelf(item)
            guard !Task.isCancelled else { return }
            onImported()
        } catch is CancellationError {
            importError = String(
                localized: "Import canceled. Partial download data was removed; you can retry.")
        } catch {
            if Task.isCancelled {
                importError = String(
                    localized: "Import canceled. Partial download data was removed; you can retry.")
                return
            }
            importError = error.localizedDescription
        }
    }

    private static func formatted(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private static func formattedElapsed(from startedAt: Date, to now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return "\(hours):\(twoDigit(minutes)):\(twoDigit(seconds))"
        }
        return "\(minutes):\(twoDigit(seconds))"
    }

    private static func twoDigit(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
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
