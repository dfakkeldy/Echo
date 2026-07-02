// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// The tri-pane study layout for macOS.
///
/// Layout:
///   Sidebar  |  Content  |  Detail
///   (TOC)    | (Reader)  | (Transcript + Notes)
///
/// A thin player bar at the bottom of the center pane shows playback controls.
struct MacTriPaneView: View {
    @Environment(MacPlayerModel.self) private var player
    @Environment(DatabaseService.self) private var dbService
    @Environment(SettingsManager.self) private var settings
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var dbServiceWired = false
    @State private var showingPlaybackOptions = false
    @State private var transcribeCoordinator: MacTranscribeCoordinator?
    @State private var showingTranscribeProgress = false
    @State private var showingQAReview = false
    @State private var showingDailyReview = false
    @State private var showingCardInbox = false
    @State private var showingStudyPlan = false
    @State private var showingAudiobookshelf = false
    @State private var studyDeckGenerationPresentation: MacStudyDeckGenerationPresentation?
    @State private var showingDeckImporter = false
    @State private var studyWorkflowAlert: (title: String, message: String)?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                MacLibraryView(db: dbService) { target in
                    player.openLibraryBook(target)
                }
                .frame(minHeight: 220, idealHeight: 280, maxHeight: 360)

                Divider()

                MacTOCTreeView()
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } content: {
            VStack(spacing: 0) {
                // Transcript-QA toolbar (shown when a book is loaded)
                if player.hasMedia {
                    transcriptQAToolbar
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    Divider()
                }

                MacReaderFeedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                playerBar
                    .frame(height: 48)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 450)
            .sheet(isPresented: $showingTranscribeProgress) {
                if let coordinator = transcribeCoordinator {
                    MacTranscribeProgressView(
                        progress: coordinator.service.progress,
                        isFinalizing: coordinator.isFinalizing,
                        onCancel: { coordinator.service.cancel() }
                    )
                }
            }
            .sheet(isPresented: $showingQAReview) {
                if let id = player.audiobookID, let db = player.dbService {
                    MacNarrationQAReviewView(db: db.writer, audiobookID: id)
                }
            }
            .sheet(isPresented: $showingDailyReview) {
                MacDailyReviewView(
                    db: dbService.writer,
                    folderURL: player.folderURL,
                    reviewNotificationsEnabled: settings.reviewNotificationsEnabled)
            }
            .sheet(isPresented: $showingCardInbox) {
                MacCardInboxView(db: dbService.writer)
            }
            .sheet(isPresented: $showingStudyPlan) {
                if let audiobookID = player.audiobookID {
                    MacStudyPlanSheetHost(
                        audiobookID: audiobookID,
                        bookTitle: player.currentTitle,
                        db: dbService.writer)
                }
            }
            .sheet(isPresented: $showingAudiobookshelf) {
                MacAudiobookshelfView(db: dbService) { url in
                    player.loadFolder(url: url)
                }
            }
            .sheet(item: $studyDeckGenerationPresentation) { presentation in
                MacStudyDeckGenerationSheetHost(presentation: presentation)
            }
        } detail: {
            MacNotesPane()
                .navigationSplitViewColumnWidth(min: 200, ideal: 300, max: 500)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            if !dbServiceWired {
                player.dbService = dbService
                player.settings = settings
                player.loadBookmarksFromDB()
                player.migrateLegacyBookmarksIfNeeded()
                dbServiceWired = true
            }
        }
        // `player.settings` is injected once, so its `didSet`/`applySettings()` only
        // seeds skip intervals at launch. Push later Preferences-window changes to the
        // live player so the skip buttons/menu use the new durations immediately.
        .onChange(of: settings.seekForwardDuration) { _, newValue in
            player.skipInterval = newValue
        }
        .onChange(of: settings.seekBackwardDuration) { _, newValue in
            player.skipBackInterval = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDailyReview)) { _ in
            showingDailyReview = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestCardInbox)) { _ in
            showingCardInbox = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestStudyPlan)) { _ in
            showingStudyPlan = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAudiobookshelf)) { _ in
            showingAudiobookshelf = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestGenerateStudyDeck)) { _ in
            presentStudyDeckGeneration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestImportDeck)) { _ in
            showingDeckImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestToggleDetailPane)) { _ in
            withAnimation {
                columnVisibility =
                    columnVisibility == .detailOnly
                    ? .all
                    : (columnVisibility == .all ? .detailOnly : .all)
            }
        }
        .fileImporter(
            isPresented: $showingDeckImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleDeckImportResult
        )
        .alert(studyWorkflowAlert?.title ?? "", isPresented: isShowingStudyWorkflowAlert) {
            Button("OK") { studyWorkflowAlert = nil }
        } message: {
            if let message = studyWorkflowAlert?.message {
                Text(message)
            }
        }
    }

    // MARK: - Player Bar

    /// The title shown in the chapter-nav bar: the current chapter's title
    /// when available, otherwise the book/track title. `Chapter.title` is
    /// optional, so an untitled chapter also falls back to `currentTitle`.
    private var macChapterTitle: String {
        if player.chapters.indices.contains(player.currentChapterIndex),
            let title = player.chapters[player.currentChapterIndex].title,
            !title.isEmpty
        {
            return title
        }
        return player.currentTitle
    }

    @ViewBuilder
    private var playerBar: some View {
        if player.hasMedia {
            HStack(spacing: 12) {
                // Chapter navigation (falls back to track label when the
                // audiobook has no chapter markers — ChapterService floors at
                // 2 chapters, so chapters.count < 2 means "no chapters").
                if player.chapters.count >= 2 {
                    HStack(spacing: 4) {
                        Button {
                            player.previousChapter()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .help("Previous chapter")
                        .accessibilityLabel(Text("Previous chapter"))
                        .disabled(player.currentChapterIndex <= 0)

                        Text(macChapterTitle)
                            .customFont(.caption, appFont: settings.appFont)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Button {
                            player.nextChapter()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.borderless)
                        .help("Next chapter")
                        .accessibilityLabel(Text("Next chapter"))
                        .disabled(player.currentChapterIndex >= player.chapters.count - 1)
                    }
                    .frame(maxWidth: 160)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(player.currentTitle)
                            .customFont(.caption, appFont: settings.appFont)
                            .lineLimit(1)
                        if player.hasMultipleTracks {
                            Text("Track \(player.currentTrackIndex + 1) of \(player.tracks.count)")
                                .customFont(.caption2, appFont: settings.appFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 120, alignment: .leading)
                }

                // Progress
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
                .disabled(player.duration <= 0)
                .controlSize(.small)
                .frame(maxWidth: 200)

                Text(formatHMS(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50)

                // Transport
                Button {
                    player.skipBackward()
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.borderless)
                .help("Skip back")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skipForward()
                } label: {
                    Image(systemName: "goforward.15")
                }
                .buttonStyle(.borderless)
                .help("Skip forward")

                // More (chapters / bookmarks / mark passage / sleep / settings)
                MacPlayerMoreMenu(onMarkPassage: onMarkPassage)

                // Playback options (speed / loop / skip / boost)
                Button {
                    showingPlaybackOptions.toggle()
                } label: {
                    Text(MacPlaybackOptionsSheet.speedLabel(player.playbackRate))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44)
                }
                .buttonStyle(.borderless)
                .help("Playback options")
                .popover(isPresented: $showingPlaybackOptions, arrowEdge: .bottom) {
                    MacPlaybackOptionsSheet()
                        .environment(player)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Text("No audiobook loaded — press ⌘O to open one.")
                    .customFont(.caption, appFont: settings.appFont)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Mark Passage

    /// Inserts a marked passage at the current playback time via the shared
    /// DatabaseService. Mirrors Echo_macOSApp.markPassage so the More menu can
    /// mark without routing through a menu-command notification.
    private var onMarkPassage: () -> Void {
        {
            guard let audiobookID = player.audiobookID, player.hasMedia else { return }
            let dao = MarkedPassageDAO(db: dbService.writer)
            _ = try? dao.insert(
                audiobookID: audiobookID,
                mediaTimestamp: player.currentTime,
                endTimestamp: nil,
                transcriptSnippet: nil,
                note: nil
            )
        }
    }

    // MARK: - Transcript-QA Toolbar

    /// Inline toolbar above the reader pane with transcript and QA actions.
    @ViewBuilder
    private var transcriptQAToolbar: some View {
        HStack(spacing: 8) {
            // Transcribe: shown when the loaded book has no EPUB blocks yet
            // (audio-only). After transcription materializes epub_block rows,
            // hasEPUB flips and the button hides.
            if !player.hasEPUB {
                Button {
                    startTranscription()
                } label: {
                    Label("Transcribe", systemImage: "text.bubble")
                }
                .help("Transcribe audiobook to enable read-along reader")
                .disabled(transcribeCoordinator?.service.progress.isRunning ?? false)
            }

            // Review Issues: shown when the loaded book might have QA issues.
            // The sheet itself loads open issues; a disabled button here is a
            // lightweight indicator that QA data exists for this book.
            Button {
                showingQAReview = true
            } label: {
                Label("Review Issues", systemImage: "ant")
            }
            .help("Review narration QA issues")

            Spacer()
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
    }

    /// Starts the transcription pipeline for the currently loaded audiobook.
    /// Creates a new MacTranscribeCoordinator, presents the progress sheet,
    /// and bumps `documentIngestionTrigger` on completion so the reader
    /// re-evaluates and switches from "no content" to showing blocks.
    private func startTranscription() {
        guard let db = player.dbService, let id = player.audiobookID else { return }
        // Use the currently-open file: player.chapters/duration describe THIS file,
        // not necessarily tracks[0], so transcribing tracks[0] would mis-window a
        // multi-file audiobook.
        guard let audioURL = player.currentURL else { return }
        let coordinator = MacTranscribeCoordinator(db: db.writer)
        transcribeCoordinator = coordinator
        showingTranscribeProgress = true
        Task { @MainActor in
            let chapters =
                player.hasChapters
                ? player.chapters
                : [
                    Chapter(
                        index: 0, title: "Full Book", startSeconds: 0, endSeconds: player.duration)
                ]
            await coordinator.transcribe(
                audiobookID: id,
                audioFileURL: audioURL,
                chapters: chapters,
                resume: true)
            player.bumpDocumentIngestionTrigger()
        }
    }

    // MARK: - Study Decks

    private var isShowingStudyWorkflowAlert: Binding<Bool> {
        Binding(
            get: { studyWorkflowAlert != nil },
            set: { if !$0 { studyWorkflowAlert = nil } }
        )
    }

    private func presentStudyDeckGeneration() {
        guard
            let presentation = MacStudyDeckGenerationPresentation(
                player: player,
                dbService: dbService
            )
        else {
            studyWorkflowAlert = (
                "Generate Study Deck Unavailable",
                "Open an audiobook or document before generating a study deck."
            )
            return
        }

        studyDeckGenerationPresentation = presentation
    }

    private func handleDeckImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let result = try DeckImportService().importDeckVNext(from: url, db: dbService.writer)
                studyWorkflowAlert = ("Import Complete", importCompletionMessage(for: result))
            } catch {
                studyWorkflowAlert = ("Import Failed", error.localizedDescription)
            }

        case .failure(let error):
            studyWorkflowAlert = ("Import Failed", error.localizedDescription)
        }
    }

    private func importCompletionMessage(for result: ImportDeckResult) -> String {
        if result.warningCount == 0 {
            return
                "Imported \(result.importedCount) cards. \(result.anchoredCount) anchored to EPUB text."
        }
        return
            "Imported \(result.importedCount) cards. \(result.anchoredCount) anchored to EPUB text. \(result.warningCount) warnings."
    }
}

private struct MacStudyDeckGenerationPresentation: Identifiable {
    let audiobookID: String
    let bookTitle: String
    let db: DatabaseWriter

    var id: String { audiobookID }

    init?(player: MacPlayerModel, dbService: DatabaseService) {
        guard player.dbService != nil,
            let audiobookID = player.audiobookID,
            let folderURL = player.folderURL
        else {
            return nil
        }

        self.audiobookID = audiobookID
        self.bookTitle = StudyPlanBookTitleResolver.resolve(
            audiobookID: audiobookID,
            folderURL: folderURL,
            db: dbService.writer,
            currentTitle: player.currentTitle
        )
        self.db = dbService.writer
    }
}

private struct MacStudyDeckGenerationSheetHost: View {
    @State private var viewModel: StudyDeckGenerationViewModel

    init(presentation: MacStudyDeckGenerationPresentation) {
        let store = APIKeyStore()
        let hasKey = store.hasKey
        let key = store.anthropicKey ?? ""
        let model = AICardGenerationSettings.selectedModel
        let generator = StudyDeckGeneratorFactory.make(
            preference: AICardGenerationSettings.providerPreference,
            hasKey: hasKey,
            fmAvailable: StudyDeckFMAvailability.isAvailable
        ) {
            AnthropicStudyDeckGenerator(
                client: AnthropicMessagesClient(apiKey: key, model: model))
        }
        _viewModel = State(
            wrappedValue: StudyDeckGenerationViewModel(
                audiobookID: presentation.audiobookID,
                bookTitle: presentation.bookTitle,
                db: presentation.db,
                generator: generator
            )
        )
    }

    var body: some View {
        StudyDeckGenerationSheet(viewModel: viewModel)
    }
}

private struct MacStudyPlanSheetHost: View {
    @State private var viewModel: StudyPlanViewModel

    init(audiobookID: String, bookTitle: String, db: DatabaseWriter) {
        _viewModel = State(
            wrappedValue: StudyPlanViewModel(
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                db: db
            )
        )
    }

    var body: some View {
        StudyPlanSheet(viewModel: viewModel)
            .frame(minWidth: 460, minHeight: 520)
    }
}

private enum StudyPlanBookTitleResolver {
    static func resolve(
        audiobookID: String,
        folderURL: URL,
        db: DatabaseWriter,
        currentTitle: String
    ) -> String {
        let audiobook = try? AudiobookDAO(db: db).get(audiobookID)
        return resolve(
            storedTitle: audiobook?.title,
            folderTitle: folderURL.lastPathComponent,
            currentTitle: currentTitle
        )
    }

    static func resolve(
        storedTitle: String?,
        folderTitle: String,
        currentTitle: String
    ) -> String {
        normalizedTitle(storedTitle)
            ?? normalizedTitle(currentTitle)
            ?? normalizedTitle(folderTitle)
            ?? "Book"
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
