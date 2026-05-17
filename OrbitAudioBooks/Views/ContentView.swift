import SwiftUI

// MARK: - UI (single screen)

struct ContentView: View {
    @Binding var pendingDeepLink: PlayerDeepLink?
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @State private var showingFolderPicker = false
    @State private var showingPlaylist = false
    @State private var showingSettings = false
    @State private var showingHelp = false
    @State private var newBookmarkDraft: BookmarkDraft? = nil
    @State private var editingBookmarkID: UUID? = nil
    @State private var isTranscriptExpanded = false
    @Environment(\.displayScale) private var displayScale

    init(pendingDeepLink: Binding<PlayerDeepLink?> = .constant(nil)) {
        _pendingDeepLink = pendingDeepLink
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
            ZStack {
            // MARK: Primary player UI (single block — gets the gray-out treatment)
            VStack(alignment: .leading, spacing: 16) {
            TranscriptOverlayView(isExpanded: $isTranscriptExpanded) {
                AlbumArtHeroView(
                    artwork: model.currentDisplayArtwork ?? model.thumbnailImage,
                    artworkVersion: model.currentDisplayArtworkVersion,
                    caption: model.chapters.count >= 2
                        ? String(localized: "Current Chapter")
                        : String(localized: "Book Title"),
                    mainText: model.chapters.count >= 2
                        ? (model.currentSubtitle.isEmpty
                            ? String(localized: "Chapter \((model.currentChapterIndex ?? 0) + 1)")
                            : model.currentSubtitle)
                        : model.currentTitle,
                    appFont: settings.appFont
                )
            }

            Spacer()

            if model.chapters.count >= 2 {
                Text(String(localized: "Chapter \((model.currentChapterIndex ?? 0) + 1) of \(model.chapters.count)"))
                    .customFont(.footnote, appFont: settings.appFont)
                    .foregroundStyle(.secondary)
            } else if !model.tracks.isEmpty {
                Text(String(localized: "Track \(model.currentIndex + 1) of \(model.tracks.count)"))
                    .customFont(.footnote, appFont: settings.appFont)
                    .foregroundStyle(.secondary)
            }

            PlayerScrubberView()

            TransportControlsView()
            }
            // Apply gray-out + opacity to the ENTIRE primary player block at once.
            .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
            .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
            .allowsHitTesting(!model.isPlayingVoiceMemo)

            // Single floating "Playing Voice Memo" badge centered over the
            // grayed-out player block.
            if model.isPlayingVoiceMemo {
                VoiceMemoOverlayView()
            }

            }
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)

            BottomToolbarView(
                showingPlaylist: $showingPlaylist,
                onCreateBookmark: { draft in newBookmarkDraft = draft }
            )
        }
        .environment(\.font, settings.appFont == SettingsManager.systemFontName ? .body : .custom(settings.appFont, size: 17, relativeTo: .body))
        .padding(.horizontal)
        .padding(.top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel(Text("Open folder"))
            }

            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel(Text("Help"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                showingFolderPicker = false
                model.loadFolder(url)
            }
        }
        .sheet(isPresented: $showingPlaylist) {
            PlaylistView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingHelp) {
            NavigationStack {
                HelpView()
                    .navigationTitle("Help")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingHelp = false }
                        }
                    }
            }
        }
        .sheet(item: Binding(
            get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
            set: { editingBookmarkID = $0?.id }
        )) { wrapper in
            EditBookmarkView(bookmarkID: wrapper.id, draft: nil)
        }
        .sheet(item: $newBookmarkDraft) { draft in
            EditBookmarkView(bookmarkID: nil, draft: draft)
        }
        .onAppear {
            // Configure remote commands early so the Watch/Now Playing UI is stable once audio starts.
            // (The model also guards to configure only once.)
            model.setSettingsManager(settings)
            model.setDisplayScale(displayScale)
            model.restoreLastSelectionIfPossible()
            applyPendingDeepLinkIfNeeded()
        }
        .onChange(of: pendingDeepLink) { _, _ in
            applyPendingDeepLinkIfNeeded()
        }
        .task {
            await storeManager.requestProducts()
        }
        .preferredColorScheme(settings.isDarkMode ? .dark : .light)
        }
    }

    private func applyPendingDeepLinkIfNeeded() {
        guard let pendingDeepLink else { return }
        model.handleDeepLink(pendingDeepLink)
        self.pendingDeepLink = nil
    }
}
