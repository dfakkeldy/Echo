import SwiftUI

struct BookSettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var isUploading = false
    @State private var uploadAlert: (title: String, message: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section("Typography") {
                    Picker("Font Override", selection: Binding(
                        get: { model.bookFontOverride ?? "inherit" },
                        set: { newValue in
                            model.updateBookFontOverride(newValue == "inherit" ? nil : newValue)
                        }
                    )) {
                        Text("Inherit Global").tag("inherit")
                        Text("Lexend").tag("Lexend")
                        Text("OpenDyslexic").tag("OpenDyslexic")
                        Text("System").tag("System")
                    }
                }

                Section("Playback Overrides") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Play Bookmarks Inline")
                            .font(.subheadline)
                        Picker("Bookmarks Inline Mode", selection: Binding(
                            get: { model.bookPlayBookmarksInlineOverride ?? "inherit" },
                            set: { newValue in
                                model.updateBookPlayBookmarksInlineOverride(newValue == "inherit" ? nil : newValue)
                            }
                        )) {
                            Text("Inherit").tag("inherit")
                            Text("Always On").tag("alwaysOn")
                            Text("Always Off").tag("alwaysOff")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Volume Boost")
                            .font(.subheadline)
                        Picker("Volume Boost Mode", selection: Binding(
                            get: { model.bookVolumeBoostOverride ?? "inherit" },
                            set: { newValue in
                                model.updateBookVolumeBoostOverride(newValue == "inherit" ? nil : newValue)
                            }
                        )) {
                            Text("Inherit").tag("inherit")
                            Text("Always On").tag("alwaysOn")
                            Text("Always Off").tag("alwaysOff")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                }

                Section("Community") {
                    Button {
                        Task { await shareAlignment() }
                    } label: {
                        if isUploading {
                            ProgressView()
                        } else {
                            Label("Share Alignment to CloudKit", systemImage: "icloud.and.arrow.up")
                        }
                    }
                    .disabled(isUploading)
                }
            }
            .navigationTitle("Book Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.font, model.resolvedAppFont == SettingsManager.systemFontName ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
        .alert(uploadAlert?.title ?? "", isPresented: Binding(
            get: { uploadAlert != nil },
            set: { if !$0 { uploadAlert = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            if let message = uploadAlert?.message {
                Text(message)
            }
        }
    }

    private func shareAlignment() async {
        guard let db = model.databaseService?.writer,
              let audiobookID = model.state.folderURL?.absoluteString else {
            uploadAlert = ("Error", "No book loaded.")
            return
        }
        
        // Extract title/author from path
        let folderURL = URL(string: audiobookID) ?? URL(fileURLWithPath: audiobookID)
        let title = folderURL.lastPathComponent
        let author = folderURL.deletingLastPathComponent().lastPathComponent
        let duration = model.state.totalBookDuration > 0 ? model.state.totalBookDuration : (model.state.durationSeconds ?? 0.0)
        
        isUploading = true
        defer { isUploading = false }
        
        do {
            let syncService = CloudKitSyncService(db: db)
            try await syncService.uploadAnchors(audiobookID: audiobookID, title: title, author: author, duration: duration)
            uploadAlert = ("Success", "Alignment anchors uploaded and shared successfully.")
        } catch {
            uploadAlert = ("Upload Failed", error.localizedDescription)
        }
    }
}
