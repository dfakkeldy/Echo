// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
import SwiftUI

struct ManageRootsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm: LibraryRootsViewModel
    @Binding private var showUnavailable: Bool
    @State private var removalCandidate: LibraryRootRecord?
    @State private var relocatingRootID: String?
    @State private var showingRelocatePicker = false

    init(db: DatabaseService, showUnavailable: Binding<Bool>) {
        _vm = State(initialValue: LibraryRootsViewModel(db: db))
        _showUnavailable = showUnavailable
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Show Missing Books", isOn: $showUnavailable)
                }

                Section("Library Roots") {
                    if vm.roots.isEmpty {
                        ContentUnavailableView(
                            "No Library Roots",
                            systemImage: "externaldrive",
                            description: Text("Add a folder from the Library tab to manage it here."))
                    } else {
                        ForEach(vm.roots, id: \.id) { root in
                            RootRow(root: root)
                                .swipeActions {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        removalCandidate = root
                                    }
                                    Button("Relocate", systemImage: "folder.badge.questionmark") {
                                        relocatingRootID = root.id
                                        showingRelocatePicker = true
                                    }
                                }
                                .contextMenu {
                                    Button("Rescan", systemImage: "arrow.clockwise") {
                                        Task { await vm.rescan(rootID: root.id) }
                                    }
                                    Button("Relocate", systemImage: "folder.badge.questionmark") {
                                        relocatingRootID = root.id
                                        showingRelocatePicker = true
                                    }
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        removalCandidate = root
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Manage Roots")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Rescan All", systemImage: "arrow.clockwise") {
                        Task { await vm.rescanAll() }
                    }
                    .disabled(vm.roots.isEmpty || vm.isWorking)
                }
            }
            .overlay {
                if vm.isWorking {
                    ProgressView("Working...")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
            }
            .onAppear { vm.reload() }
            .alert("Library Root Error", isPresented: errorPresented) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .confirmationDialog(
                "Remove Library Root",
                isPresented: removalPresented,
                presenting: removalCandidate
            ) { root in
                Button("Keep Books as Missing", systemImage: "eye.slash") {
                    Task { await vm.remove(rootID: root.id, forgetBooks: false) }
                }
                Button("Forget Books", systemImage: "trash", role: .destructive) {
                    Task { await vm.remove(rootID: root.id, forgetBooks: true) }
                }
                Button("Cancel", role: .cancel) {
                    removalCandidate = nil
                }
            } message: { root in
                Text("Remove \(root.displayName) from your Library?")
            }
            .sheet(isPresented: $showingRelocatePicker) {
                FolderPicker { url in
                    showingRelocatePicker = false
                    guard let relocatingRootID else { return }
                    Task { await vm.relocate(rootID: relocatingRootID, to: url) }
                    self.relocatingRootID = nil
                }
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { isPresented in
                if !isPresented { vm.errorMessage = nil }
            }
        )
    }

    private var removalPresented: Binding<Bool> {
        Binding(
            get: { removalCandidate != nil },
            set: { isPresented in
                if !isPresented { removalCandidate = nil }
            }
        )
    }
}

private struct RootRow: View {
    let root: LibraryRootRecord

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(root.displayName)
                Text(root.lastScannedAt ?? "Never scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "externaldrive")
        }
    }
}
#endif
