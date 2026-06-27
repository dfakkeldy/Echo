// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// A wrapper to make UUID Identifiable for use with `.sheet(item:)`.
struct IdentifiableUUID: Identifiable, Hashable {
    let id: UUID
}

struct CompanionDocumentImportRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case epub
        case pdf

        var loadingMessage: String {
            switch self {
            case .epub: "Importing EPUB..."
            case .pdf: "Importing PDF..."
            }
        }
    }

    let id: UUID
    let url: URL
    let kind: Kind

    init(result: Result<[URL], Error>) throws {
        let urls = try result.get()
        guard let url = urls.first else {
            throw CompanionDocumentImportSelectionError.noSelection
        }
        try self.init(url: url)
    }

    init(url: URL) throws {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "epub":
            self.id = UUID()
            self.url = url
            self.kind = .epub
        case "pdf":
            self.id = UUID()
            self.url = url
            self.kind = .pdf
        default:
            throw CompanionDocumentImportSelectionError.unsupportedFileType(url)
        }
    }
}

enum CompanionDocumentImportSelectionError: LocalizedError, Equatable {
    case noSelection
    case unsupportedFileType(URL)

    nonisolated var errorDescription: String? {
        switch self {
        case .noSelection:
            return "No document was selected."
        case .unsupportedFileType(let url):
            return "Choose an EPUB or PDF document. \(url.lastPathComponent) is not supported."
        }
    }
}

private enum DocumentImportPhase {
    case idle
    case importing(id: UUID, kind: CompanionDocumentImportRequest.Kind)
    case failed(DocumentImportFailure)

    var loadingMessage: String? {
        guard case .importing(_, let kind) = self else { return nil }
        return kind.loadingMessage
    }

    var failureMessage: String? {
        guard case .failed(let failure) = self else { return nil }
        return failure.message
    }

    var activeRequestID: UUID? {
        guard case .importing(let id, _) = self else { return nil }
        return id
    }
}

private struct DocumentImportFailure {
    let message: String

    init(error: Error) {
        self.message = error.localizedDescription
    }
}

private struct DocumentImportProgressOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            ProgressView {
                Text(message)
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }
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
    @State private var showingStudyNotesExport = false
    @State private var editingIdentifiableUUID: IdentifiableUUID?
    @State private var documentImportPhase: DocumentImportPhase = .idle
    @State private var documentImportTask: Task<Void, Never>?

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
                            showBookSettings: { showingBookSettings = true },
                            onConnectServer: { showingSettings = true }
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
                                ReaderEmptyState(
                                    hasLoadedBook: model.folderURL != nil,
                                    canAddEPUB: !model.narrationPlaybackState.isRunning,
                                    onImportBook: { showingFolderPicker = true },
                                    onAddEPUB: { model.showingDocumentImporter = true }
                                )
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
                onAddDocumentTap: (model.folderURL != nil
                    && !model.narrationPlaybackState.isRunning)
                    ? { model.showingDocumentImporter = true } : nil,
                onExportTap: (model.folderURL != nil && !model.narrationPlaybackState.isRunning)
                    ? { showingExport = true } : nil,
                onStudyNotesExportTap: (model.folderURL != nil
                    && !model.narrationPlaybackState.isRunning)
                    ? { showingStudyNotesExport = true } : nil
            )

            // The bottom deck is root-owned so Now Playing and Reader share the
            // exact same bottom edge during tab transitions.
            if !model.isPlayingVoiceMemo {
                VStack {
                    Spacer()
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
        .sheet(isPresented: $showingStudyNotesExport) {
            if let folderURL = model.folderURL,
                let writer = model.databaseService?.writer
            {
                StudyNotesExportView(
                    audiobookID: folderURL.absoluteString,
                    bookTitle: model.currentTitle,
                    sourceFolderURL: folderURL,
                    databaseWriter: writer,
                    chapters: model.chapters
                )
            }
        }
        .sheet(isPresented: $model.showPaywall) {
            PaywallView(context: model.paywallContext)
        }
        .alert(
            "Folder Access Not Saved",
            isPresented: $model.showingBookmarkPersistenceWarning
        ) {
            Button("OK", role: .cancel) {}
            Button("Choose Folder") { showingFolderPicker = true }
        } message: {
            Text(
                "Echo could not save permanent access to this folder. You can keep using it now, but you may need to choose it again after relaunch."
            )
        }
        .alert(
            "Can’t Find This Book’s Files",
            isPresented: $model.showingMissingBookWarning
        ) {
            Button("OK", role: .cancel) {}
            Button("Choose Book") { showingFolderPicker = true }
        } message: {
            Text(
                "The files for your last book may have moved or been deleted. Choose the book again to keep listening."
            )
        }
        .fileImporter(
            isPresented: $model.showingDocumentImporter,
            allowedContentTypes: companionDocumentTypes,
            allowsMultipleSelection: false
        ) { result in
            beginDocumentImport(with: result)
        }
        .overlay {
            if let message = documentImportPhase.loadingMessage {
                DocumentImportProgressOverlay(message: message)
            }
        }
        .alert(
            "Couldn’t Import Document",
            isPresented: documentImportErrorPresented
        ) {
            Button("OK", role: .cancel) {
                documentImportPhase = .idle
            }
        } message: {
            Text(documentImportPhase.failureMessage ?? "Import failed.")
        }
        .onAppear {
            ReviewPromptManager.shared.recordSessionStart()
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
            if newPhase == .active {
                ReviewPromptManager.shared.recordSessionStart()
            } else if newPhase == .background || newPhase == .inactive {
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

    private var companionDocumentTypes: [UTType] {
        [UTType(filenameExtension: "epub") ?? .data, .pdf]
    }

    private var documentImportErrorPresented: Binding<Bool> {
        Binding(
            get: {
                if case .failed = documentImportPhase { return true }
                return false
            },
            set: { isPresented in
                if !isPresented, case .failed = documentImportPhase {
                    documentImportPhase = .idle
                }
            }
        )
    }

    private func beginDocumentImport(with result: Result<[URL], Error>) {
        guard documentImportPhase.activeRequestID == nil else { return }

        do {
            let request = try CompanionDocumentImportRequest(result: result)
            documentImportPhase = .importing(id: request.id, kind: request.kind)
            documentImportTask = Task {
                await importCompanionDocument(request)
            }
        } catch {
            handleDocumentImportError(error, requestID: nil)
        }
    }

    private func importCompanionDocument(_ request: CompanionDocumentImportRequest) async {
        do {
            let url = request.url
            switch request.kind {
            case .pdf:
                try await model.importPDFDocument(from: url)
            case .epub:
                try await model.importEPUBDocument(from: url)
            }
            guard isActiveDocumentImport(request.id), !Task.isCancelled else { return }
            documentImportPhase = .idle
            documentImportTask = nil
        } catch {
            handleDocumentImportError(error, requestID: request.id)
        }
    }

    private func handleDocumentImportError(_ error: Error, requestID: UUID?) {
        if let requestID, !isActiveDocumentImport(requestID) {
            return
        }

        if isDocumentImportCancellation(error) {
            documentImportPhase = .idle
        } else {
            documentImportPhase = .failed(DocumentImportFailure(error: error))
        }
        documentImportTask = nil
    }

    private func isActiveDocumentImport(_ requestID: UUID) -> Bool {
        documentImportPhase.activeRequestID == requestID
    }

    private func isDocumentImportCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }

        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.Code.userCancelled.rawValue
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
