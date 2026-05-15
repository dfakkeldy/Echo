import SwiftUI
import Observation

// MARK: - UI (single screen)

struct ContentView: View {
    @Binding var pendingDeepLink: PlayerDeepLink?
    @State private var model = PlayerModel()
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @State private var showingFolderPicker = false
    @State private var showingPlaylist = false
    @State private var showingSettings = false
    @State private var newBookmarkDraft: BookmarkDraft? = nil
    @State private var editingBookmarkID: UUID? = nil
    @Environment(\.displayScale) private var displayScale

    init(pendingDeepLink: Binding<PlayerDeepLink?> = .constant(nil)) {
        _pendingDeepLink = pendingDeepLink
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
            ZStack {
            // MARK: Primary player UI (single block — gets the gray-out treatment)
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .center, spacing: 12) {
                ArtworkTranscriptOverlayView(model: model)

                VStack(alignment: .center, spacing: 6) {
                    Text(model.chapters.count >= 2 ? "Current Chapter" : "Current Title")
                        .customFont(.caption, appFont: settings.appFont)
                        .foregroundStyle(.secondary)
                    Text(model.chapters.count >= 2 ? (model.currentSubtitle.isEmpty ? "Chapter \(model.currentChapterIndex ?? 0 + 1)" : model.currentSubtitle) : model.currentTitle)
                        .customFont(.title2, weight: .semibold, appFont: settings.appFont)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            if model.chapters.count >= 2 {
                Text("Chapter \((model.currentChapterIndex ?? 0) + 1) of \(model.chapters.count)")
                    .customFont(.footnote, appFont: settings.appFont)
                    .foregroundStyle(.secondary)
            } else if !model.tracks.isEmpty {
                Text("Track \(model.currentIndex + 1) of \(model.tracks.count)")
                    .customFont(.footnote, appFont: settings.appFont)
                    .foregroundStyle(.secondary)
            }

            PlayerScrubberView(model: model)

            TransportControlsView(model: model)
            }
            // Apply gray-out + opacity to the ENTIRE primary player block at once.
            .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
            .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
            .allowsHitTesting(!model.isPlayingVoiceMemo)
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)

            // Single floating "Playing Voice Memo" badge centered over the
            // grayed-out player block.
            if model.isPlayingVoiceMemo {
                VoiceMemoOverlayView(model: model)
            }

            }
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)

            BottomToolbarView(
                model: model,
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
                .accessibilityLabel("Open folder")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                showingFolderPicker = false
                model.loadFolder(url)
            }
        }
        .sheet(isPresented: $showingPlaylist) {
            PlaylistView(model: model)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .sheet(item: Binding(
            get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
            set: { editingBookmarkID = $0?.id }
        )) { wrapper in
            EditBookmarkView(model: model, bookmarkID: wrapper.id, draft: nil)
        }
        .sheet(item: $newBookmarkDraft) { draft in
            EditBookmarkView(model: model, bookmarkID: nil, draft: draft)
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
