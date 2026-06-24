// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// A wrapper to make UUID Identifiable for use with `.sheet(item:)`.
struct IdentifiableUUID: Identifiable, Hashable {
    let id: UUID
}

struct RootTabView: View {
    @Binding var pendingDeepLink: PlayerDeepLink?
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingFolderPicker = false
    @State private var showingSettings = false
    @State private var showingPlaybackOptions = false
    /// Player-More chapter-navigation sheet for the non-Now-Playing dock overlay
    /// (WS-C). Distinct binding from NowPlayingTab's, but both present the same
    /// ChapterPickerSheet — they are never on screen at the same time.
    @State private var showingChapterPicker = false
    @State private var showingBookSettings = false
    // showingHelp presentation state resides on PlayerModel
    @State private var newBookmarkDraft: BookmarkDraft? = nil
    @State private var editingBookmarkID: UUID? = nil
    @State private var showingFidget = false
    @State private var showingStats = false
    /// Unified ".m4b export" sheet, presented from the global More menu. The
    /// resolver auto-detects narrated-vs-imported, so one action covers both.
    @State private var showingExport = false
    @State private var showingReview = false
    @State private var studySessionViewModel: StudySessionViewModel?
    @State private var editingIdentifiableUUID: IdentifiableUUID?

    @State private var nowPlayingPath = NavigationPath()
    @State private var readPath = NavigationPath()

    @SceneStorage("nowPlayingPathData") private var nowPlayingPathData: Data?
    @SceneStorage("readPathData") private var readPathData: Data?

    init(pendingDeepLink: Binding<PlayerDeepLink?> = .constant(nil)) {
        _pendingDeepLink = pendingDeepLink
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            // Saturated dynamic background ONLY on the player tab
            if model.selectedTab == .nowPlaying {
                AdaptiveBackground()
            } else {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
            }

            // Per-tab NavigationStacks for independent navigation state.
            Group {
                switch model.selectedTab {
                case .nowPlaying:
                    NavigationStack(path: $nowPlayingPath) {
                        NowPlayingTab(
                            showsBookSettings: model.folderURL != nil,
                            openFolder: { showingFolderPicker = true },
                            showHelp: { model.showingHelp = true },
                            showBookSettings: { showingBookSettings = true }
                        )
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .navigationDestination(for: NavigationDestination.self) { dest in
                            dest.view(using: model)
                        }
                    }
                case .read:
                    NavigationStack(path: $readPath) {
                        Group {
                            if model.hasEPUB {
                                ReaderTab(folderURL: model.folderURL!)
                            } else if model.hasPDF {
                                PDFDocumentView(folderURL: model.folderURL!)
                            } else if model.hasStandaloneTranscript,
                                let folder = model.folderURL,
                                let db = model.databaseService
                            {
                                StandaloneTranscriptView(
                                    audiobookID: folder.absoluteString,
                                    db: db.writer
                                )
                            } else {
                                ReaderEmptyState()
                            }
                        }
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .navigationDestination(for: NavigationDestination.self) { dest in
                            dest.view(using: model)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Unified Top Header System (Row 1: global navigation), overlaid
            // at the top of the Z-stack on top of the content behind it.
            UnifiedTopHeader(
                onFolderTap: { showingFolderPicker = true },
                onSettingsTap: { showingSettings = true },
                onBookSettingsTap: { showingBookSettings = true },
                onHelpTap: { model.showingHelp = true },
                onStatsTap: { showingStats = true },
                onFidgetTap: { showingFidget = true },
                onAddEPUBTap: (model.folderURL != nil && !model.narrationPlaybackState.isRunning)
                    ? { model.showingDocumentImporter = true } : nil,
                onExportTap: (model.folderURL != nil && !model.narrationPlaybackState.isRunning)
                    ? { showingExport = true } : nil
            )

            // The bottom deck is root-owned so Now Playing and Reader share the
            // exact same bottom edge during tab transitions.
            if !model.isPlayingVoiceMemo {
                VStack(spacing: 0) {
                    Spacer()
                    if model.folderURL != nil {
                        DashboardShelf(onReviewTap: launchStudySession)
                    }
                    UnifiedBottomDock(
                        onCreateBookmark: { draft in newBookmarkDraft = draft },
                        onShowPlaybackOptions: { showingPlaybackOptions = true },
                        // WS-C C2: the player-More closures are required on the dock.
                        // Full wiring on this non-NowPlaying overlay (chapter sheet
                        // binding) is task C3; Bookmarks/Settings reuse existing state.
                        onShowChapters: { showingChapterPicker = true },
                        onShowBookmarks: { model.selectedTab = .read },
                        onShowSettings: { showingSettings = true }
                    )
                    .environment(\.showPlaybackOptions, { showingPlaybackOptions = true })
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // NOTE: the player/background layers ignore the safe area themselves
        // (AdaptiveBackground + the systemBackground fill), so the ZStack no
        // longer needs a blanket `.ignoresSafeArea(.bottom)`. Dropping it lets
        // the bottom dock respect the home indicator — its rounded bottom edge
        // is visible and it anchors to the true bottom edge instead of bleeding
        // underneath the indicator.
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                showingFolderPicker = false
                // A picked folder, audio file, or lone study EPUB all flow
                // through the same loader; an EPUB opens as an audio-less book.
                model.loadFolder(url)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        // Player-More "Chapters" from the overlaid dock (Read/Study tabs).
        .sheet(isPresented: $showingChapterPicker) {
            ChapterPickerSheet(chapters: model.chapters) { chapter in
                model.seek(toSeconds: chapter.startSeconds + 0.05)
            }
        }
        .sheet(isPresented: $showingPlaybackOptions) {
            PlaybackOptionsSheet()
        }
        .sheet(isPresented: $showingBookSettings) {
            BookSettingsView(model: model)
        }
        .sheet(isPresented: $model.showingHelp) {
            NavigationStack {
                HelpView()
                    .navigationTitle("Help")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { model.showingHelp = false }
                        }
                    }
            }
        }
        .sheet(item: $editingIdentifiableUUID) { wrapper in
            EditBookmarkView(bookmarkID: wrapper.id, draft: nil)
        }
        .sheet(item: $newBookmarkDraft) { draft in
            EditBookmarkView(bookmarkID: nil, draft: draft)
        }
        .sheet(item: $model.activeBookmarkDraft) { draft in
            EditBookmarkView(bookmarkID: nil, draft: draft)
        }
        .sheet(isPresented: $showingReview) {
            if let vm = studySessionViewModel {
                StudySessionView(viewModel: vm)
            }
        }
        .sheet(isPresented: $showingFidget) {
            FidgetOverlayView(
                audiobookID: model.folderURL?.lastPathComponent ?? "unknown",
                frameStream: model.audioEngine.visualizerTap?.frames
            )
        }
        .sheet(isPresented: $showingStats) {
            NavigationStack {
                StatsView()
                    .navigationTitle("Stats")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingStats = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingExport) {
            if let id = model.folderURL?.absoluteString, let writer = model.databaseService?.writer
            {
                ExportProgressView(
                    audiobookID: id,
                    bookTitle: model.currentTitle,
                    cacheDirectory: PlayerModel.narrationCacheDirectory(),
                    databaseWriter: writer)
            }
        }
        .sheet(isPresented: $model.showPaywall) {
            PaywallView(context: model.paywallContext)
        }
        .fileImporter(
            isPresented: $model.showingDocumentImporter,
            allowedContentTypes: companionEPUBTypes,
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            model.importEPUB(from: url)
        }
        .onAppear {
            model.setSettingsManager(settings)
            model.setDisplayScale(displayScale)
            model.restoreLastSelectionIfPossible()
            applyPendingDeepLinkIfNeeded()

            // Restore navigation paths from SceneStorage
            if let data = nowPlayingPathData,
                let representation = try? JSONDecoder().decode(
                    NavigationPath.CodableRepresentation.self, from: data
                )
            {
                nowPlayingPath = NavigationPath(representation)
            }
            if let data = readPathData,
                let representation = try? JSONDecoder().decode(
                    NavigationPath.CodableRepresentation.self, from: data
                )
            {
                readPath = NavigationPath(representation)
            }
        }
        .onChange(of: pendingDeepLink) { _, _ in
            applyPendingDeepLinkIfNeeded()
        }
        .onChange(of: model.pendingNavigationDestination) { _, destination in
            guard let destination else { return }
            pushNavigationDestination(destination)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                // Persist navigation paths
                if let codable = nowPlayingPath.codable,
                    let data = try? JSONEncoder().encode(codable)
                {
                    nowPlayingPathData = data
                }
                if let codable = readPath.codable,
                    let data = try? JSONEncoder().encode(codable)
                {
                    readPathData = data
                }
                model.persistCurrentState()
            }
        }
        .onChange(of: editingBookmarkID) { _, newValue in
            editingIdentifiableUUID = newValue.map { IdentifiableUUID(id: $0) }
        }
        .task {
            await storeManager.requestProducts()
        }
        .preferredColorScheme(colorScheme(for: settings.appAppearance))
        .onAppear {
            model.uiColorScheme = colorScheme
        }
        .onChange(of: colorScheme) { _, newScheme in
            model.uiColorScheme = newScheme
        }
    }

    private func colorScheme(for appearance: String) -> ColorScheme? {
        switch appearance {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    private var companionEPUBTypes: [UTType] {
        [UTType(filenameExtension: "epub") ?? .data]
    }

    private func launchStudySession() {
        guard let db = model.databaseService else { return }
        let vm = StudySessionViewModel(db: db.writer)
        vm.onRequestAssignmentPlayback = { [weak model] card in
            guard let model else { return }
            playStudyAssignment(card, model: model)
        }

        do {
            try vm.loadQueue()
            studySessionViewModel = vm
            showingReview = true
        } catch {
            studySessionViewModel = nil
            showingReview = false
        }
    }

    @MainActor
    private func playStudyAssignment(_ card: Flashcard, model: PlayerModel) {
        let bookURL = URL(string: card.audiobookID) ?? URL(fileURLWithPath: card.audiobookID)
        if model.folderURL?.absoluteString != card.audiobookID {
            model.loadFolder(bookURL, autoplay: false)
        }
        model.selectedTab = .nowPlaying

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            model.seek(toSeconds: max(0, card.mediaTimestamp + 0.05))
            model.play()
        }
    }

    private func applyPendingDeepLinkIfNeeded() {
        guard let pendingDeepLink else { return }
        model.handleDeepLink(pendingDeepLink)
        self.pendingDeepLink = nil
        // Process any navigation destination set by handleDeepLink.
        if let destination = model.pendingNavigationDestination {
            pushNavigationDestination(destination)
        }
    }

    /// Pushes a navigation destination onto the appropriate tab's NavigationStack
    /// and clears the pending property on PlayerModel.
    private func pushNavigationDestination(_ destination: NavigationDestination) {
        model.pendingNavigationDestination = nil
        switch destination {
        case .settingsAppearance, .settingsAudio, .settingsChimes,
            .settingsSmartRewind, .settingsPhonePlayer, .settingsWatchApp,
            .settingsProTranscripts:
            nowPlayingPath.append(destination)
        case .chapter:
            readPath.append(destination)
        }
    }
}
