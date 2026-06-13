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
    @State private var showingReview = false
    @State private var reviewViewModel: DailyReviewViewModel?
    @State private var editingIdentifiableUUID: IdentifiableUUID?

    init(pendingDeepLink: Binding<PlayerDeepLink?> = .constant(nil)) {
        _pendingDeepLink = pendingDeepLink
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ZStack(alignment: .top) {
                // Saturated dynamic background ONLY on the player tab
                if model.selectedTab == .nowPlaying {
                    AdaptiveBackground()
                } else {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                }

                // Main Tab Content. Each tab reserves its own top clearance for
                // Row 1 natively (via `.safeAreaInset`), so the header can be a
                // simple Z-stack overlay without displacing the child views.
                Group {
                    switch model.selectedTab {
                    case .nowPlaying:
                        NowPlayingTab(
                            showsBookSettings: model.folderURL != nil,
                            openFolder: { showingFolderPicker = true },
                            showHelp: { model.showingHelp = true },
                            showBookSettings: { showingBookSettings = true },
                            showSettings: { showingSettings = true },
                            onCreateBookmark: { draft in newBookmarkDraft = draft },
                            onShowFidget: { showingFidget = true }
                        )
                    case .read:
                        if model.hasEPUB {
                            ReaderTab(folderURL: model.folderURL!)
                        } else if model.hasPDF {
                            PDFDocumentView(folderURL: model.folderURL!)
                        } else if model.hasStandaloneTranscript,
                                  let folder = model.folderURL,
                                  let db = model.databaseService {
                            StandaloneTranscriptView(
                                audiobookID: folder.absoluteString,
                                db: db.writer
                            )
                        } else {
                            ReaderEmptyState()
                        }
                    case .timeline:
                        TimelineTab(
                            onReviewTap: { launchReview() },
                            onEditBookmark: { id in editingBookmarkID = id },
                            onCreateBookmark: { draft in newBookmarkDraft = draft }
                        )
                    case .stats:
                        NavigationStack {
                            StatsView()
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
                    onHelpTap: { model.showingHelp = true }
                )

                // UnifiedBottomDock is only overlaid on non-NowPlaying views.
                // In NowPlayingTab, it is placed at the bottom of the VStack.
                if model.selectedTab != .nowPlaying && !model.isPlayingVoiceMemo {
                    VStack {
                        Spacer()
                        UnifiedBottomDock(onCreateBookmark: { draft in newBookmarkDraft = draft }, onShowFidget: { showingFidget = true })
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .toolbarVisibility(.hidden, for: .navigationBar)
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
                FidgetOverlayView(audiobookID: model.folderURL?.lastPathComponent ?? "unknown")
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
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background || newPhase == .inactive {
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
