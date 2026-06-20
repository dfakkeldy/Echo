// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ABSBrowseView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var libraries: [ABSLibrary] = []
    @State private var selectedLibrary: ABSLibrary?
    @State private var items: [ABSLibraryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchQuery = ""
    @State private var searchResults: [ABSLibraryItem]? = nil

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn't load", systemImage: "wifi.slash",
                        description: Text(errorMessage))
                } else {
                    List {
                        if libraries.count > 1 {
                            Picker("Library", selection: $selectedLibrary) {
                                ForEach(libraries) { lib in Text(lib.name).tag(Optional(lib)) }
                            }
                        }
                        ForEach(searchResults ?? items) { item in
                            NavigationLink {
                                ABSItemDetailView(item: item, onImported: { dismiss() })
                            } label: {
                                ABSItemRow(
                                    item: item,
                                    coverURL: model.makeAudiobookshelfService()?.coverURL(
                                        itemID: item.id))
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
            .task(id: selectedLibrary) { await loadItems() }
            .task(id: searchQuery) { await runSearch() }
        }
    }

    private func runSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = nil
            return
        }
        guard let service = model.makeAudiobookshelfService(), let lib = selectedLibrary else {
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))  // debounce keystrokes
            try Task.checkCancellation()
            let results = try await service.search(libraryID: lib.id, query: q)
            try Task.checkCancellation()
            searchResults = results
        } catch is CancellationError {
            // superseded by a newer keystroke — ignore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadLibraries() async {
        guard let service = model.makeAudiobookshelfService() else {
            errorMessage = "No server connected."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            libraries = try await service.libraries()
            selectedLibrary = libraries.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadItems() async {
        guard let service = model.makeAudiobookshelfService(), let lib = selectedLibrary else {
            return
        }
        do {
            let result = try await service.items(libraryID: lib.id).results
            try Task.checkCancellation()  // bail if the selection already moved on
            items = result
        } catch is CancellationError {
            // superseded by a newer selection — ignore
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ABSItemRow: View {
    let item: ABSLibraryItem
    let coverURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: coverURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    AsyncImage(url: model.makeAudiobookshelfService()?.coverURL(itemID: item.id)) {
                        image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(
                            .secondary)
                    }
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }
            Section {
                LabeledContent("Title", value: item.title ?? "Untitled")
                if let author = item.author { LabeledContent("Author", value: author) }
                if let narrator = item.media?.metadata?.narrator {
                    LabeledContent("Narrator", value: narrator)
                }
                if let duration = item.duration {
                    LabeledContent("Duration", value: Self.formatted(duration))
                }
                if let n = item.numTracks { LabeledContent("Tracks", value: "\(n)") }
            }
            if let description = item.media?.metadata?.description, !description.isEmpty {
                Section("Description") { Text(description).font(.callout) }
            }
            Section {
                if isImporting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Downloading…")
                    }
                } else {
                    Button {
                        Task { await importBook() }
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

    private func importBook() async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            try await model.addFromAudiobookshelf(item)
            onImported()
        } catch {
            importError = error.localizedDescription
        }
    }

    private static func formatted(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
