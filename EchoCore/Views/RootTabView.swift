import SwiftUI

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
    @State private var showingBookSettings = false
    // showingHelp presentation state resides on PlayerModel
    @State private var newBookmarkDraft: BookmarkDraft? = nil
    @State private var editingBookmarkID: UUID? = nil
    @State private var showingFidget = false
    @State private var showingStats = false
    @State private var showingReview = false
    @State private var reviewViewModel: DailyReviewViewModel?
    @State private var editingIdentifiableUUID: IdentifiableUUID?

    @State private var nowPlayingPath = NavigationPath()
    @State private var readPath = NavigationPath()
    @State private var timelinePath = NavigationPath()

    @SceneStorage("nowPlayingPathData") private var nowPlayingPathData: Data?
    @SceneStorage("readPathData") private var readPathData: Data?
    @SceneStorage("timelinePathData") private var timelinePathData: Data?

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
                            showBookSettings: { showingBookSettings = true },
                            showSettings: { showingSettings = true },
                            onCreateBookmark: { draft in newBookmarkDraft = draft }
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
                case .timeline:
                    NavigationStack(path: $timelinePath) {
                        TimelineTab(
                            onReviewTap: { launchReview() },
                            onEditBookmark: { id in editingBookmarkID = id },
                            onCreateBookmark: { draft in newBookmarkDraft = draft }
                        )
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
                onFidgetTap: { showingFidget = true }
            )

            // UnifiedBottomDock is only overlaid on non-NowPlaying views.
            // In NowPlayingTab, it is placed at the bottom of the VStack.
            if model.selectedTab != .nowPlaying && !model.isPlayingVoiceMemo {
                VStack {
                    Spacer()
                    UnifiedBottomDock(
                        onCreateBookmark: { draft in newBookmarkDraft = draft })
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
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
            if let vm = reviewViewModel {
                FlashcardReviewSession(viewModel: vm)
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
        .sheet(isPresented: $model.showPaywall) {
            PaywallView(context: model.paywallContext)
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
            if let data = timelinePathData,
                let representation = try? JSONDecoder().decode(
                    NavigationPath.CodableRepresentation.self, from: data
                )
            {
                timelinePath = NavigationPath(representation)
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
                if let codable = timelinePath.codable,
                    let data = try? JSONEncoder().encode(codable)
                {
                    timelinePathData = data
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

    private func launchReview() {
        guard let db = model.databaseService else { return }
        let vm = DailyReviewViewModel(
            db: db.writer, folderURL: model.folderURL, snippetPlayer: model.snippetPlayer)
        vm.onRequestSnippetPlay = { [weak model] url, start, end in
            model?.snippetPlayer.play(url: url, startTime: start, endTime: end)
        }
        vm.loadDueCards()
        reviewViewModel = vm
        showingReview = true
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
