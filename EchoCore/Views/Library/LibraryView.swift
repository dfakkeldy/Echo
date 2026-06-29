// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
import SwiftUI

struct LibraryView: View {
    @State private var vm: LibraryViewModel
    @State private var showingManageRoots = false
    @State private var showingRecoveryFolderPicker = false
    let onAddFolder: () -> Void
    let onConnectServer: () -> Void

    init(
        db: DatabaseService,
        openBook: @escaping (LibraryOpenTarget) -> Void,
        onAddFolder: @escaping () -> Void,
        onConnectServer: @escaping () -> Void
    ) {
        _vm = State(initialValue: LibraryViewModel(db: db, openBook: openBook))
        self.onAddFolder = onAddFolder
        self.onConnectServer = onConnectServer
    }

    var body: some View {
        Group {
            if vm.isEmpty {
                emptyState
            } else {
                LibraryShelfGrid(sections: vm.sections, statusMap: vm.statusMap) { book in
                    vm.open(book)
                }
            }
        }
        .overlay {
            if vm.isScanning {
                ProgressView("Scanning...")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                LibraryBrowseByView(selectedAxis: vm.selectedAxis) { axis in
                    vm.selectAxis(axis)
                }
                Menu("Library Options", systemImage: "ellipsis.circle") {
                    Toggle("Show Missing Books", isOn: showUnavailable)
                    Button("Manage Roots", systemImage: "externaldrive.badge.gearshape") {
                        showingManageRoots = true
                    }
                }
                Button("Add Folder", systemImage: "folder.badge.plus", action: onAddFolder)
            }
        }
        .sheet(isPresented: $showingManageRoots) {
            ManageRootsView(db: vm.database, showUnavailable: showUnavailable)
        }
        .sheet(isPresented: $showingRecoveryFolderPicker) {
            FolderPicker { url in
                showingRecoveryFolderPicker = false
                Task { await vm.relocatePendingRecoveryBook(to: url) }
            }
        }
        .onAppear { vm.reload() }
        .alert("Couldn't open book", isPresented: errorPresented) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .confirmationDialog(
            "Missing Book",
            isPresented: recoveryPresented,
            presenting: vm.pendingRecoveryBook
        ) { _ in
            Button("Relocate Folder", systemImage: "folder.badge.questionmark") {
                showingRecoveryFolderPicker = true
            }
            Button("Remove Book", systemImage: "trash", role: .destructive) {
                Task { await vm.removePendingRecoveryBook() }
            }
            Button("Cancel", role: .cancel) {
                vm.pendingRecoveryBook = nil
            }
        } message: { book in
            Text("\(book.title) is missing. Relocate its library folder or remove it from the shelf.")
        }
    }

    private var showUnavailable: Binding<Bool> {
        Binding(
            get: { vm.showUnavailable },
            set: { vm.setShowUnavailable($0) }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { isPresented in
                if !isPresented { vm.errorMessage = nil }
            }
        )
    }

    private var recoveryPresented: Binding<Bool> {
        Binding(
            get: { vm.pendingRecoveryBook != nil },
            set: { isPresented in
                if !isPresented { vm.pendingRecoveryBook = nil }
            }
        )
    }

    private var emptyState: some View {
        LibraryEmptyState(
            onAddFolder: onAddFolder,
            onConnectServer: onConnectServer
        )
    }
}

private struct LibraryEmptyState: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let onAddFolder: () -> Void
    private let onConnectServer: () -> Void

    init(
        onAddFolder: @escaping () -> Void,
        onConnectServer: @escaping () -> Void
    ) {
        self.onAddFolder = onAddFolder
        self.onConnectServer = onConnectServer
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "books.vertical")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("Your Library")
                    .font(.title)
                    .bold()
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(
                    "Add a folder of audiobooks to build your shelf. Echo plays your files where they live; it never copies them."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

                actionLayout {
                    Button("Open a Folder", systemImage: "folder", action: onAddFolder)
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)

                    Button(
                        "Connect a Server",
                        systemImage: "externaldrive.connected.to.line.below",
                        action: onConnectServer
                    )
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
                .controlSize(dynamicTypeSize.isAccessibilitySize ? .large : .regular)
                .padding(.top, 6)
            }
            .frame(maxWidth: 430)
            .padding(.horizontal)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 32 : 96)
            .padding(.bottom, bottomDockClearance)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var actionLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(spacing: 12))
        } else {
            AnyLayout(HStackLayout(spacing: 12))
        }
    }

    private var bottomDockClearance: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 180 : 120
    }
}
#endif
