// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct MacLibraryView: View {
    @State private var libraryVM: LibraryViewModel
    @State private var rootsVM: LibraryRootsViewModel

    init(db: DatabaseService, openBook: @escaping (LibraryOpenTarget) -> Void) {
        _libraryVM = State(initialValue: LibraryViewModel(db: db, openBook: openBook))
        _rootsVM = State(initialValue: LibraryRootsViewModel(db: db))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 10)
                .padding(.top, 10)

            if libraryVM.isEmpty {
                ContentUnavailableView {
                    Label("Library", systemImage: "books.vertical")
                } description: {
                    Text("Add a folder to browse local audiobooks.")
                } actions: {
                    Button("Add Folder", systemImage: "folder.badge.plus", action: addFolder)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(libraryVM.sections, id: \.title) { section in
                        if !section.books.isEmpty {
                            Section(section.title) {
                                ForEach(section.books, id: \.id) { book in
                                    Button {
                                        libraryVM.open(book)
                                    } label: {
                                        MacLibraryBookRow(
                                            book: book,
                                            processing: libraryVM.statusMap[book.id]?.processing ?? [])
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Section("Roots") {
                        Toggle("Show Missing Books", isOn: showUnavailable)
                        if rootsVM.roots.isEmpty {
                            Text("No roots")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(rootsVM.roots, id: \.id) { root in
                                MacLibraryRootRow(root: root) {
                                    Task {
                                        await rootsVM.rescan(rootID: root.id)
                                        libraryVM.reload()
                                    }
                                } remove: {
                                    Task {
                                        await rootsVM.remove(rootID: root.id, forgetBooks: false)
                                        libraryVM.reload()
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .overlay {
            if libraryVM.isScanning || rootsVM.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .onAppear {
            libraryVM.reload()
            rootsVM.reload()
        }
        .confirmationDialog(
            "Missing Book",
            isPresented: recoveryPresented,
            presenting: libraryVM.pendingRecoveryBook
        ) { _ in
            Button("Relocate Folder") {
                relocateMissingBook()
            }
            Button("Remove Book", role: .destructive) {
                Task { await libraryVM.removePendingRecoveryBook() }
            }
            Button("Cancel", role: .cancel) {
                libraryVM.pendingRecoveryBook = nil
            }
        } message: { book in
            Text("\(book.title) is missing. Relocate its library folder or remove it from the shelf.")
        }
        .alert("Library Error", isPresented: errorPresented) {
            Button("OK") {
                libraryVM.errorMessage = nil
                rootsVM.errorMessage = nil
            }
        } message: {
            Text(libraryVM.errorMessage ?? rootsVM.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Library", systemImage: "books.vertical")
                .font(.headline)

            Spacer()

            Menu {
                ForEach(LibraryAxis.allCases, id: \.self) { axis in
                    Button(axis.label, systemImage: axis.systemImage) {
                        libraryVM.selectAxis(axis)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Browse by")

            Button("Add Folder", systemImage: "folder.badge.plus", action: addFolder)
                .labelStyle(.iconOnly)
                .help("Add folder")
        }
    }

    private var showUnavailable: Binding<Bool> {
        Binding(
            get: { libraryVM.showUnavailable },
            set: { libraryVM.setShowUnavailable($0) }
        )
    }

    private var recoveryPresented: Binding<Bool> {
        Binding(
            get: { libraryVM.pendingRecoveryBook != nil },
            set: { isPresented in
                if !isPresented { libraryVM.pendingRecoveryBook = nil }
            }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { libraryVM.errorMessage != nil || rootsVM.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    libraryVM.errorMessage = nil
                    rootsVM.errorMessage = nil
                }
            }
        )
    }

    private func addFolder() {
        guard let url = chooseFolder() else { return }
        Task {
            await libraryVM.addRoot(url: url)
            rootsVM.reload()
        }
    }

    private func relocateMissingBook() {
        guard let url = chooseFolder() else { return }
        Task {
            await libraryVM.relocatePendingRecoveryBook(to: url)
            rootsVM.reload()
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct MacLibraryBookRow: View {
    let book: AudiobookRecord
    let processing: ProcessingStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: book.isAvailable ? "book.closed" : "exclamationmark.triangle")
                .foregroundStyle(book.isAvailable ? Color.secondary : Color.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let author = book.author {
                        Text(author)
                            .lineLimit(1)
                    }
                    if !book.isAvailable {
                        Text("Missing")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            LibraryStatusDot(processing: processing)
        }
        .contentShape(.rect)
        .opacity(book.isAvailable ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}

private struct MacLibraryRootRow: View {
    let root: LibraryRootRecord
    let rescan: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(root.displayName)
                    .lineLimit(1)
                Text(root.lastScannedAt ?? "Never scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button("Rescan", systemImage: "arrow.clockwise", action: rescan)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Rescan root")

            Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Keep books as missing and remove root")
        }
    }
}

private extension LibraryAxis {
    var label: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .author: "Author"
        case .topic: "Topic"
        case .folder: "Folder"
        case .studyStatus: "Study Status"
        case .processingStatus: "Processing Status"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyAdded: "clock"
        case .author: "person"
        case .topic: "tag"
        case .folder: "folder"
        case .studyStatus: "checkmark.circle"
        case .processingStatus: "wand.and.sparkles"
        }
    }
}
