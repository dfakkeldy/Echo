import SwiftUI

struct RootTabView: View {
    @Binding var pendingDeepLink: PlayerDeepLink?
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.displayScale) private var displayScale

    @State private var showingFolderPicker = false
    @State private var showingSettings = false
    @State private var showingBookSettings = false
    @State private var showingHelp = false
    @State private var newBookmarkDraft: BookmarkDraft? = nil
    @State private var editingBookmarkID: UUID? = nil
    @State private var showingReview = false
    @State private var reviewViewModel: DailyReviewViewModel?

    init(pendingDeepLink: Binding<PlayerDeepLink?> = .constant(nil)) {
        _pendingDeepLink = pendingDeepLink
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    switch model.selectedTab {
                    case .nowPlaying:
                        NowPlayingTab()
                    case .read:
                        if model.hasEPUB {
                            ReaderTab(folderURL: model.folderURL!)
                        } else {
                            ReaderEmptyState()
                        }
                    case .timeline:
                        TimelineTab(
                            onReviewTap: { launchReview() },
                            onEditBookmark: { id in editingBookmarkID = id },
                            onCreateBookmark: { draft in newBookmarkDraft = draft }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
 
                if !model.isPlayingVoiceMemo {
                    VStack(spacing: 8) {
                        if model.selectedTab == .timeline && model.folderURL != nil && !model.tracks.isEmpty {
                            PlayerControlBar()
                        }
                        BottomToolbarView(onCreateBookmark: { draft in newBookmarkDraft = draft })
                    }
                }
            }
            .overlay(alignment: .top) {
                if model.selectedTab == .nowPlaying {
                    NowPlayingTopToolbar(
                        showsBookSettings: model.folderURL != nil,
                        openFolder: { showingFolderPicker = true },
                        showHelp: { showingHelp = true },
                        showBookSettings: { showingBookSettings = true },
                        showSettings: { showingSettings = true }
                    )
                }
            }
            .ignoresSafeArea(edges: model.selectedTab != .nowPlaying ? [] : .top)
            .toolbarVisibility(model.selectedTab != .nowPlaying ? .automatic : .hidden, for: .navigationBar)
            .toolbarBackground(model.selectedTab != .nowPlaying ? .automatic : .hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(model.selectedTab != .nowPlaying ? .automatic : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(Text("Open folder"))
                }

                ToolbarItem(placement: .principal) {
                    Text(Duration.seconds(model.currentPlaybackTime).formatted(.time(pattern: .minuteSecond)))
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundColor(.secondary)
                }
 
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Global Settings", systemImage: "gearshape")
                        }
                        
                        if model.folderURL != nil {
                            Button {
                                showingBookSettings = true
                            } label: {
                                Label("Book Settings", systemImage: "document.badge.gearshape")
                            }
                        }
                        
                        Button {
                            showingHelp = true
                        } label: {
                            Label("Help", systemImage: "questionmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("More"))
                }
            }
            .sheet(isPresented: $showingFolderPicker) {
                FolderPicker { url in
                    showingFolderPicker = false
                    model.loadFolder(url)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingBookSettings) {
                BookSettingsView(model: model)
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
            .sheet(item: $model.activeBookmarkDraft) { draft in
                EditBookmarkView(bookmarkID: nil, draft: draft)
            }
            .sheet(isPresented: $showingReview) {
                if let vm = reviewViewModel {
                    FlashcardReviewSession(viewModel: vm)
                }
            }
            .onAppear {
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

    private func launchReview() {
        guard let db = model.databaseService else { return }
        let vm = DailyReviewViewModel(db: db.writer, folderURL: model.folderURL, snippetPlayer: model.snippetPlayer)
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
    }
}

private struct NowPlayingTopToolbar: View {
    let showsBookSettings: Bool
    let openFolder: () -> Void
    let showHelp: () -> Void
    let showBookSettings: () -> Void
    let showSettings: () -> Void

    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { _ in
            HStack {
                controlGroup {
                    toolbarButton(
                        systemName: "folder",
                        accessibilityLabel: "Open folder",
                        action: openFolder
                    )
                }

                Spacer()
                
                Text(Duration.seconds(model.currentPlaybackTime).formatted(.time(pattern: .minuteSecond)))
                    .font(.subheadline.monospacedDigit().bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .nowPlayingGlassToolbar()

                Spacer()

                controlGroup {
                    Menu {
                        Button {
                            showSettings()
                        } label: {
                            Label("Global Settings", systemImage: "gearshape")
                        }
                        
                        if showsBookSettings {
                            Button {
                                showBookSettings()
                            } label: {
                                Label("Book Settings", systemImage: "document.badge.gearshape")
                            }
                        }
                        
                        Button {
                            showHelp()
                        } label: {
                            Label("Help", systemImage: "questionmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("More"))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, NowPlayingLayout.topToolbarTopPadding)
        }
        .frame(height: NowPlayingLayout.topOverlayHeight)
    }

    private func toolbarButton(
        systemName: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private func controlGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .nowPlayingGlassToolbar()
    }
}

private extension View {
    @ViewBuilder
    func nowPlayingGlassToolbar() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
    }
}
