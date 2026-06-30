// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

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
        .onReceive(NotificationCenter.default.publisher(for: .requestToggleDetailPane)) { _ in
            withAnimation {
                columnVisibility =
                    columnVisibility == .detailOnly
                    ? .all
                    : (columnVisibility == .all ? .detailOnly : .all)
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
                    player.skip(by: -Double(player.skipInterval))
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
                    player.skip(by: Double(player.skipInterval))
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
        guard !player.tracks.isEmpty else { return }
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
                audioFileURL: player.tracks[0],
                chapters: chapters,
                resume: true)
            player.bumpDocumentIngestionTrigger()
        }
    }
}
