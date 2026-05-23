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
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if model.showingTimeline {
                        TimelineTab(
                            onReviewTap: { launchReview() },
                            onEditBookmark: { id in editingBookmarkID = id },
                            onCreateBookmark: { draft in newBookmarkDraft = draft }
                        )
                    } else {
                        NowPlayingTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !model.isPlayingVoiceMemo {
                    BottomToolbarView(onCreateBookmark: { draft in newBookmarkDraft = draft })
                }
            }
            .overlay(alignment: .top) {
                if !model.showingTimeline {
                    NowPlayingTopToolbar(
                        showsBookSettings: model.folderURL != nil,
                        openFolder: { showingFolderPicker = true },
                        showHelp: { showingHelp = true },
                        showBookSettings: { showingBookSettings = true },
                        showSettings: { showingSettings = true }
                    )
                }
            }
            .ignoresSafeArea(edges: model.showingTimeline ? [] : .top)
            .toolbarVisibility(model.showingTimeline ? .automatic : .hidden, for: .navigationBar)
            .toolbarBackground(model.showingTimeline ? .automatic : .hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(model.showingTimeline ? .automatic : .hidden, for: .navigationBar)
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
                    HStack(spacing: 12) {
                        if model.folderURL != nil {
                            Button {
                                showingBookSettings = true
                            } label: {
                                Image(systemName: "document.badge.gearshape")
                            }
                            .accessibilityLabel(Text("Book Settings"))
                        }
                        
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(Text("Global Settings"))
                    }
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

    var body: some View {
        GeometryReader { _ in
            HStack {
                controlGroup {
                    toolbarButton(
                        systemName: "folder",
                        accessibilityLabel: "Open folder",
                        action: openFolder
                    )

                    toolbarButton(
                        systemName: "questionmark.circle",
                        accessibilityLabel: "Help",
                        action: showHelp
                    )
                }

                Spacer()

                controlGroup {
                    if showsBookSettings {
                        toolbarButton(
                            systemName: "document.badge.gearshape",
                            accessibilityLabel: "Book Settings",
                            action: showBookSettings
                        )
                    }

                    toolbarButton(
                        systemName: "gearshape",
                        accessibilityLabel: "Global Settings",
                        action: showSettings
                    )
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
