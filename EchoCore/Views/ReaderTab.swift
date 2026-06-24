// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import GRDB
import SwiftUI
import UIKit
import os.log

struct ReaderTab: View {
    let folderURL: URL
    @Environment(PlayerModel.self) var model
    @Environment(SettingsManager.self) private var settingsManager

    @State var viewModel: ReaderFeedViewModel?
    @State var showChapterPickerForBlockID: String? = nil
    @State var showCardColorPickerForBlockID: String? = nil
    @State var showChapterThemePickerForBlockID: String? = nil
    @State private var isHeaderVisible = true
    @State private var autoScrollEnabled = true
    @State private var topPartTitle: String? = nil
    @State private var topChapterTitle: String? = nil
    @State private var topSectionTitle: String? = nil
    @State private var topChapterThemeColor: String? = nil
    @State var pulseBlockID: String? = nil
    @State private var forceScrollBlockID: String? = nil
    @State private var forceScrollTrigger: Int = 0

    /// AVAudioPlayer for voice memo playback (Phase 4). Retained so playback
    /// continues until the user taps a different memo or leaves the screen.
    @State private var memoPlayer: AVAudioPlayer?
    /// Recorder for capturing standalone voice memos (Phase 4). Destination is
    /// the book folder's `voice-memos/` subdirectory so relative `filePath` rows
    /// survive across relaunches when re-joined with `folderURL`.
    @State private var memoRecorder = VoiceMemoRecorder(
        destinationDirectory: FileLocations.applicationSupportDirectory
            .appendingPathComponent("voice-memos-tmp", isDirectory: true))
    @State private var isComposingReaderNote = false
    @State private var readerNoteText = ""
    @State private var composingNoteBlockID: String?
    @State private var recordingMemoBlockID: String?

    /// Coalesces per-chapter `.timelineItemsIngested` posts during a narration
    /// render into a single trailing `reload()` (reload re-reads the whole book on
    /// the main thread — running it per chapter is O(chapters²) over a render run).
    @State private var readerReloadToken = 0
    @State private var showSessions = false
    @AppStorage("hasSeenReaderContextMenuHint") private var hasSeenContextMenuHint = false
    @State private var showAlignmentBanner = false
    @State private var hasDismissedAlignmentBanner = false
    let haptic = UIImpactFeedbackGenerator(style: .medium)
    let logger = Logger(category: "ReaderTab")

    @State private var readerSettings = ReaderSettings(
        fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8", appFont: "System"
    )

    @ViewBuilder
    private var topChapterHeaderView: some View {
        HStack(spacing: 0) {
            Button {
                model.previousSectionOrRestart()
                Haptic.play(.light)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.tracks.isEmpty)
            .accessibilityLabel(Text("Previous section"))

            VStack(spacing: 4) {
                if let part = topPartTitle, !part.isEmpty {
                    Text(part)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }
                if let title = topChapterTitle, !title.isEmpty {
                    let isTop = topPartTitle?.isEmpty ?? true
                    Text(title)
                        .font(isTop ? .headline : .subheadline)
                        .foregroundStyle(isTop ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.top, isTop ? 8 : 0)
                }
                if let section = topSectionTitle, !section.isEmpty {
                    Text(section)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                } else {
                    Spacer().frame(height: 4)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                model.nextSection()
                Haptic.play(.light)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.tracks.isEmpty)
            .accessibilityLabel(Text("Next section"))
        }
        // Audit D2: the header floats in the same tonal world as the rest of
        // the app — chapter theme color when set, else the cover accent.
        .background(
            Rectangle()
                .fill(topChapterThemeColor.map { Color(hex: $0) } ?? model.coverTheme.accent)
                .opacity(topChapterThemeColor != nil ? 0.3 : 0.12)
        )
        .background(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 2)
        .zIndex(1)
    }

    @ViewBuilder
    private var feedCollectionView: some View {
        if let vm = viewModel {
            let query: String? = model.epubSearchText.isEmpty ? nil : model.epubSearchText
            let bindableVM = Bindable(vm)

            ReaderFeedCollectionView(
                sections: vm.displaySections,
                activeBlockID: bindableVM.activeBlockID,
                activeWord: vm.activeWord,
                isHeaderVisible: $isHeaderVisible,
                autoScrollEnabled: $autoScrollEnabled,
                topPartTitle: $topPartTitle,
                topChapterTitle: $topChapterTitle,
                topSectionTitle: $topSectionTitle,
                topChapterThemeColor: $topChapterThemeColor,
                settings: readerSettings,
                alignmentStatusByBlockID: vm.alignmentStatusByBlockID,
                audioStartTimeByBlockID: vm.audioStartTimeByBlockID,
                chapterHasAudio: vm.chapterHasAudio,
                chapterThemeColorByKey: vm.chapterThemeColorByKey,
                openChapterKey: vm.openChapterKey,
                onToggleChapter: { (chapterKey: Int) -> Void in
                    vm.toggleChapter(chapterKey)
                },
                searchQuery: query,
                pulseBlockID: pulseBlockID,
                forceScrollBlockID: forceScrollBlockID,
                forceScrollTrigger: forceScrollTrigger,
                onTapBlock: { (blockID: String) -> Void in
                    tapBlock(blockID)
                },
                onContextMenu: { (block: EPubBlockRecord) -> UIContextMenuConfiguration? in
                    buildContextMenu(block: block)
                },
                onChapterHeaderContextMenu: { (chapterIndex: Int) -> UIContextMenuConfiguration? in
                    let state = vm.chapterOffState(chapterIndex)
                    let hasAudio = vm.chapterHasAudio[chapterIndex] ?? false

                    return UIContextMenuConfiguration(
                        identifier: nil, previewProvider: nil
                    ) { _ in
                        // Turn off/on everywhere (toggles whole chapter).
                        let everywhereOn = (state == .allOn)
                        let everywhere = UIAction(
                            title: everywhereOn ? "Turn off everywhere" : "Turn on everywhere",
                            image: UIImage(systemName: everywhereOn ? "eye.slash" : "eye")
                        ) { _ in
                            vm.setChapterOff(.all, on: everywhereOn, chapterIndex: chapterIndex)
                        }

                        // Granular: Listen (audio).
                        let listen = UIAction(
                            title: state.isAudioOff ? "Turn on listening" : "Turn off listening",
                            image: UIImage(systemName: "headphones"),
                            attributes: hasAudio ? [] : .disabled
                        ) { _ in
                            vm.setChapterOff(
                                .audio, on: !state.isAudioOff, chapterIndex: chapterIndex)
                        }

                        // Granular: Narrate (shares the same manifest audio flag in v1).
                        // v1 limitation: narration and listening map to the same `isEnabled`
                        // flag; a distinct narration off-switch requires separately-addressable
                        // narration tracks (future work).
                        let narrate = UIAction(
                            title: state.isAudioOff ? "Turn on narration" : "Turn off narration",
                            image: UIImage(systemName: "waveform"),
                            attributes: hasAudio ? [] : .disabled
                        ) { _ in
                            vm.setChapterOff(
                                .audio, on: !state.isAudioOff, chapterIndex: chapterIndex)
                        }

                        // Granular: Cards/text (epub off flag).
                        let cards = UIAction(
                            title: state.isEpubOff
                                ? "Turn on reading & cards" : "Turn off reading & cards",
                            image: UIImage(systemName: "text.book.closed")
                        ) { _ in
                            vm.setChapterOff(
                                .epub, on: !state.isEpubOff, chapterIndex: chapterIndex)
                        }

                        let granular = UIMenu(
                            title: "", options: .displayInline, children: [listen, narrate, cards])
                        return UIMenu(title: "", children: [everywhere, granular])
                    }
                },
                offState: { chapterIndex in vm.chapterOffState(chapterIndex) },
                onPlayMemo: { memo in
                    // Re-join the stored relative filePath with the book's voice-memos
                    // subfolder so the file is found correctly after relaunch.
                    let memoDir =
                        folderURL
                        .appendingPathComponent("voice-memos", isDirectory: true)
                    let fileURL = memoDir.appendingPathComponent(memo.filePath)
                    memoPlayer?.stop()
                    memoPlayer = try? AVAudioPlayer(contentsOf: fileURL)
                    memoPlayer?.play()
                }
            )
        }
    }

    /// The reader's own floating header: the search/utilities row (when visible),
    /// the sticky chapter-hierarchy title, and any active hint banners.
    ///
    /// Hosted via `.safeAreaInset` so the collection reserves exactly this view's
    /// measured height — replacing the old hard-coded `topInset: 110`.
    @ViewBuilder
    private func readerHeaderOverlay(vm: ReaderFeedViewModel) -> some View {
        VStack(spacing: 0) {
            if isHeaderVisible {
                localUtilitiesRow
                    .transition(.move(edge: .top).combined(with: .opacity))
                filterBar(vm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            topChapterHeaderView

            // ── Context menu / alignment hints ──
            if !hasSeenContextMenuHint {
                hintBanner(
                    icon: "hand.point.up.left",
                    message:
                        "Long-press any card to align it with the audio, change its color, bookmark it, or copy text.",
                    dismissible: true,
                    onDismiss: { withAnimation { hasSeenContextMenuHint = true } }
                )
            } else if showAlignmentBanner && !hasDismissedAlignmentBanner {
                hintBanner(
                    icon: "align.horizontal.center",
                    message:
                        "The alignment was estimated automatically. Long-press any paragraph and choose \"Align to Now\" to make it exact — this makes the book fully searchable.",
                    dismissible: true,
                    onDismiss: { withAnimation { hasDismissedAlignmentBanner = true } }
                )
            }
        }
        .background(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 2)
    }

    var body: some View {
        readerPresentationContent()
    }

    private func readerPresentationContent() -> some View {
        readerAuxiliarySheetContent()
            .alert(
                "Auto-Alignment Failed",
                isPresented: Binding(
                    get: { viewModel?.showAutoAlignmentFailedAlert ?? false },
                    set: { viewModel?.showAutoAlignmentFailedAlert = $0 }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(viewModel?.autoAlignmentErrorMessage ?? "An unknown error occurred.")
            }
            .background(Color.clear)
    }

    private func readerAuxiliarySheetContent() -> some View {
        readerPickerSheetContent()
            .sheet(
                isPresented: Binding(
                    get: { viewModel?.showAutoAlignmentProgress ?? false },
                    set: { viewModel?.showAutoAlignmentProgress = $0 }
                )
            ) {
                if let vm = viewModel {
                    AutoAlignmentProgressView(
                        sharedState: vm.autoAlignmentState,
                        onCancel: { vm.autoAlignmentTask?.cancel() }
                    )
                }
            }
    }

    private func readerPickerSheetContent() -> some View {
        @Bindable var model = model

        return readerPrimarySheetContent()
            .sheet(item: chapterPickerBinding) { ident in
                let blockID = ident.id
                ChapterPickerSheet(
                    chapters: model.alignmentPickerChapters,
                    onSelect: { selectedChapter in
                        alignBlock(
                            blockID,
                            to: selectedChapter.startSeconds,
                            source: .chapterBoundary
                        )
                        showChapterPickerForBlockID = nil
                    }
                )
            }
            .sheet(item: cardColorPickerBinding) { ident in
                cardColorPickerSheet(blockID: ident.id)
            }
            .sheet(item: chapterThemePickerBinding) { ident in
                chapterThemePickerSheet(blockID: ident.id)
            }
    }

    private func readerPrimarySheetContent() -> some View {
        @Bindable var model = model

        return readerLifecycleContent()
            .sheet(isPresented: $model.showReaderSettings) {
                ReaderSettingsSheet(settings: $readerSettings)
            }
            .sheet(isPresented: $showSessions) {
                readerSessionsSheet()
            }
            .sheet(isPresented: $isComposingReaderNote) {
                ReaderNoteComposerSheet(
                    text: $readerNoteText,
                    onCancel: cancelReaderNote,
                    onSave: saveReaderNote
                )
            }
            .sheet(isPresented: $model.showReaderTOC) {
                readerTOCSheet()
            }
    }

    private func readerLifecycleContent() -> some View {
        readerRootContent()
            .animation(.easeInOut(duration: 0.25), value: isHeaderVisible)
            .onAppear(perform: prepareReader)
            .onChange(of: settingsManager.appFont) { _, newFont in
                updateReaderAppFont(newFont)
            }
            .onChange(of: readerSettings.fontSize) { _, newSize in
                settingsManager.readerFontSize = newSize
            }
            .onChange(of: readerSettings.lineSpacing) { _, newLineSpacing in
                settingsManager.readerLineSpacing = newLineSpacing
            }
            .onChange(of: readerSettings.cardTintHex) { _, newHex in
                settingsManager.readerCardTint = newHex
            }
            .onChange(of: model.epubSearchText) { _, newValue in
                viewModel?.searchQuery = newValue.isEmpty ? nil : newValue
            }
            .onChange(of: viewModel?.activeBlockID) { _, newValue in
                model.readerCaptureAnchorBlockID = newValue
            }
            .onChange(of: model.epubScrollToActiveTrigger) { _, _ in
                scrollReaderToActiveBlock()
            }
            .onChange(of: model.currentPlaybackTime) { _, newPos in
                updateActiveReaderBlock(time: newPos)
            }
            .onChange(of: model.currentIndex) { _, _ in
                updateActiveReaderBlockForCurrentTrack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) {
                handleTimelineItemsIngested($0)
            }
            .task(id: readerReloadToken) {
                await reloadReaderAfterTimelineIngestion()
            }
            .onDisappear(perform: tearDownReader)
    }

    @ViewBuilder
    private func readerRootContent() -> some View {
        if let vm = viewModel {
            readerLoadedContent(vm: vm)
        } else {
            readerLoadingContent()
        }
    }

    @ViewBuilder
    private func readerLoadedContent(vm: ReaderFeedViewModel) -> some View {
        // The collection fills the screen and scrolls behind the translucent
        // headers. Each `.safeAreaInset` reserves native top/bottom clearance:
        //   1. the reader's own header (self-measuring),
        //   2. Row 1 of UnifiedTopHeader (overlaid in RootTabView),
        //   3. the floating bottom dock.
        // (2) must match the header's real height, or the reader's own
        // header tucks under the glass — hence `rowOneHeight`, not a
        // hard-coded constant that goes stale when the chips resize.
        VStack(spacing: 0) {
            if let recap = vm.recap {
                recapCard(recap)
                    .padding(.bottom, 8)
            }
            feedCollectionView
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            readerHeaderOverlay(vm: vm)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: UnifiedTopHeader.rowOneHeight)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: model.bottomInset)
        }
    }

    private func readerLoadingContent() -> some View {
        VStack {
            Spacer()
            ProgressView("Loading EPUB...")
            Spacer()
        }
    }

    private func readerSessionsSheet() -> some View {
        NavigationStack {
            SessionsListView(audiobookID: folderURL.absoluteString)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSessions = false }
                    }
                }
        }
    }

    @ViewBuilder
    private func readerTOCSheet() -> some View {
        @Bindable var model = model

        if let vm = viewModel {
            EPUBTOCSheet(
                sections: vm.sections,
                tocEntries: vm.tocEntries,
                activeBlockID: vm.activeBlockID,
                onSelect: { blockID in
                    seekToBlockAndScroll(blockID)
                    forceScrollBlockID = blockID
                    forceScrollTrigger += 1
                    model.showReaderTOC = false
                }
            )
        }
    }

    private func cardColorPickerSheet(blockID: String) -> some View {
        CardColorPickerSheet(blockID: blockID) { blockID, colorHex in
            if let db = model.databaseService {
                let blockDAO = EPubBlockDAO(db: db.writer)
                do {
                    try blockDAO.setCardColor(colorHex, blockID: blockID)
                    viewModel?.reload()
                } catch {
                    // Best-effort
                }
            }
            showCardColorPickerForBlockID = nil
        }
    }

    private func chapterThemePickerSheet(blockID: String) -> some View {
        CardColorPickerSheet(blockID: blockID) { blockID, colorHex in
            if let db = model.databaseService {
                let blockDAO = EPubBlockDAO(db: db.writer)
                do {
                    let allBlocks = allReaderBlocks()

                    if let block = allBlocks.first(where: { $0.id == blockID }),
                        let chapterIndex = block.chapterIndex
                    {
                        try blockDAO.setChapterThemeColor(
                            colorHex, chapterIndex: chapterIndex, audiobookID: block.audiobookID
                        )
                        viewModel?.reload()
                        // Update the header theme before the collection scrolls again.
                        topChapterThemeColor = colorHex
                    }
                } catch {
                    // Best-effort
                }
            }
            showChapterThemePickerForBlockID = nil
        }
    }

    private func prepareReader() {
        let overrides = BookPreferencesService.loadOverrides(for: folderURL.absoluteString)
        readerSettings = ReaderSettings.resolved(
            fontSizeOverride: nil,
            lineSpacingOverride: nil,
            cardTintOverride: nil,
            appFontOverride: overrides.font,
            globalFontSize: settingsManager.readerFontSize,
            globalLineSpacing: settingsManager.readerLineSpacing,
            globalCardTint: settingsManager.readerCardTint,
            globalAppFont: settingsManager.appFont
        )
        loadViewModel()
    }

    private func updateReaderAppFont(_ newFont: String) {
        let overrides = BookPreferencesService.loadOverrides(for: folderURL.absoluteString)
        readerSettings.appFont = BookPreferencesService.resolveAppFont(
            override: overrides.font,
            globalFont: newFont
        )
    }

    private func scrollReaderToActiveBlock() {
        autoScrollEnabled = true
        if let activeID = viewModel?.activeBlockID {
            viewModel?.expandChapter(containingBlockID: activeID)
            forceScrollBlockID = activeID
            forceScrollTrigger += 1
        }
    }

    private func updateActiveReaderBlock(time: TimeInterval) {
        viewModel?.updateActiveBlock(
            time: time,
            currentTrackChapterIndices: currentTrackChapterIndices,
            isPlaying: model.isPlaying
        )
    }

    private func updateActiveReaderBlockForCurrentTrack() {
        // Re-scope + re-resolve at a track boundary: the per-track playback time
        // can be identical across tracks, so without re-scoping the highlight
        // would stay stuck in the previous track's chapter.
        updateActiveReaderBlock(time: model.currentPlaybackTime)
    }

    private func handleTimelineItemsIngested(_ notification: Notification) {
        guard let ingestedID = notification.userInfo?["audiobookID"] as? String,
            ingestedID == folderURL.absoluteString
        else { return }
        // Coalesce instead of reloading synchronously per post: narration posts
        // this once per rendered chapter, and reload() re-reads the whole book
        // on the main thread. Bump a token so a burst (e.g. the cached-chapter
        // backfill) collapses into one trailing reload.
        readerReloadToken &+= 1
    }

    private func reloadReaderAfterTimelineIngestion() async {
        guard readerReloadToken > 0 else { return }
        // Quiet window; a newer post cancels this task and restarts the wait,
        // so only the last post in a burst actually triggers the reload.
        try? await Task.sleep(for: .milliseconds(250))
        viewModel?.reload()
    }

    private func tearDownReader() {
        viewModel?.autoAlignmentTask?.cancel()
        clearReaderCaptureActions()
    }

    private func allReaderBlocks() -> [EPubBlockRecord] {
        viewModel?.sections.flatMap(\.items).compactMap { item -> EPubBlockRecord? in
            if case .block(let block) = item { return block }
            return nil
        } ?? []
    }

    // MARK: - Phase-3 filter bar + recap card

    /// Phase-3 content-type chips + scope selector. Sits directly above the feed.
    @ViewBuilder
    private func filterBar(_ vm: ReaderFeedViewModel) -> some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FeedContentType.allCases, id: \.self) { type in
                        let disabled = (type == .bookmarks || type == .cards)  // fork 3: Phase 2 dep
                        Button {
                            vm.filter.contentType = type
                        } label: {
                            Text(Self.chipLabel(type))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        vm.filter.contentType == type
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.secondary.opacity(0.12))
                                )
                                .overlay(
                                    Capsule().stroke(
                                        vm.filter.contentType == type
                                            ? Color.accentColor : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .opacity(disabled ? 0.4 : 1)
                        .accessibilityLabel(Self.chipLabel(type))
                        .accessibilityAddTraits(vm.filter.contentType == type ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal)
            }

            Picker(
                "Scope",
                selection: Binding(
                    get: { vm.filter.scope == .wholeBook ? 0 : 1 },
                    set: { vm.filter.scope = ($0 == 0) ? .wholeBook : .lastSession }
                )
            ) {
                Text("Whole book").tag(0)
                Text("Last session").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
    }

    private static func chipLabel(_ type: FeedContentType) -> String {
        switch type {
        case .everything: return "Everything"
        case .audio: return "Audio"
        case .text: return "Text"
        case .pics: return "Pics"
        case .picsAndAudio: return "Pics + Audio"
        case .bookmarks: return "Bookmarks"
        case .cards: return "Cards"
        }
    }

    /// Phase-3 recap card shown atop a scoped feed (only when `.lastSession` resolves).
    @ViewBuilder
    private func recapCard(_ recap: SessionRecap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last session")
                .font(.headline)
            HStack(spacing: 16) {
                recapLabel("clock", Self.minutesText(recap.listenedSeconds))
                if !recap.coveredChapterIndices.isEmpty {
                    recapLabel("book", Self.chaptersText(recap.coveredChapterIndices))
                }
                if recap.bookmarkCount > 0 {
                    recapLabel("bookmark", "\(recap.bookmarkCount)")
                }
                if recap.cardCount > 0 {
                    recapLabel("rectangle.on.rectangle", "\(recap.cardCount)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(recap.startedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.tertiary)
            // GPS ("where") deferred to Phase 5 — session_location has no writer yet.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func recapLabel(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
    }

    private static func minutesText(_ seconds: TimeInterval) -> String {
        let mins = Int((seconds / 60).rounded())
        return "\(mins) min"
    }

    private static func chaptersText(_ indices: [Int]) -> String {
        guard let first = indices.first, let last = indices.last else { return "" }
        // chapter index is 0-based; show 1-based to the reader.
        return first == last ? "Ch \(first + 1)" : "Ch \(first + 1)–\(last + 1)"
    }

    // MARK: - Helpers

    /// The set of EPUB chapter indices belonging to the currently-playing track,
    /// used to scope read-along resolution (Layer 1 of the multi-file fix).
    ///
    /// The scope must follow the **playing chapter**, not the queue position. For
    /// narration those diverge: a dropped image-only chapter leaves a gap in the
    /// plan, and C3 resume front-truncates the plan so `currentIndex == 0` while
    /// the playing chapter is `resumeIndex`. The absolute chapter is encoded in the
    /// narration track filename (`<safeID>-ch<N>-<voice>.m4a`), so we recover it via
    /// `NarrationFileNaming.chapterIndex(fromFileName:)`. For MP3-folder books there
    /// is no such filename and track position equals `chapter_index` 1:1, so the
    /// parse returns `nil` and the shared helper falls back to `{currentIndex}`.
    ///
    /// Single-track and multi-M4B fallbacks (→ `nil`, no scoping) live in the shared
    /// `ReaderActiveBlockResolver.trackChapterScope` so iOS and macOS share one path.
    private var currentTrackChapterIndices: Set<Int>? {
        let tracks = model.tracks
        let currentIndex = model.currentIndex
        var playingChapterIndex: Int?
        if tracks.indices.contains(currentIndex) {
            playingChapterIndex = NarrationFileNaming.chapterIndex(
                fromFileName: tracks[currentIndex].url.lastPathComponent)
        }
        return ReaderActiveBlockResolver.trackChapterScope(
            trackCount: tracks.count,
            isMultiM4B: model.isMultiM4B,
            currentIndex: currentIndex,
            playingChapterIndex: playingChapterIndex)
    }

    private struct IdentifiableBlockID: Identifiable {
        let id: String
    }

    private var chapterPickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showChapterPickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showChapterPickerForBlockID = $0?.id }
        )
    }

    private var cardColorPickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showCardColorPickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showCardColorPickerForBlockID = $0?.id }
        )
    }

    private var chapterThemePickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showChapterThemePickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showChapterThemePickerForBlockID = $0?.id }
        )
    }

    private func loadViewModel() {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        // Pass the book folder so the long-press off menu's audio toggle can write
        // `isEnabled` on the mapped tracks (without it, audio-off silently no-ops).
        let vm = ReaderFeedViewModel(
            audiobookID: audiobookID, db: db.writer, playlistFolderURL: folderURL)
        vm.reload()
        self.viewModel = vm

        // Point the recorder at the book's own voice-memos subfolder so relative
        // filePath rows survive relaunches when re-joined with `folderURL`.
        memoRecorder = VoiceMemoRecorder(
            destinationDirectory:
                folderURL
                .appendingPathComponent("voice-memos", isDirectory: true))

        // Check if alignment is entirely auto-estimated (no user-created anchors yet).
        // Only show the alignment banner after the one-time context-menu hint has been dismissed.
        showAlignmentBanner = !vm.hasUserAlignmentAnchors(audiobookID: audiobookID)
        configureReaderCaptureActions()
    }

    /// Tapping a paragraph card seeks to it AND starts playing (the user wants to
    /// hear from there). Uses the canonical user-seek (`model.seek(toSeconds:)`,
    /// which refreshes progress/artwork/now-playing) — not the bare engine seek —
    /// and gives feedback instead of a silent no-op when the block has no audio yet.
    private func tapBlock(_ blockID: String) {
        guard let vm = viewModel else { return }
        let time = vm.audioStartTime(for: blockID, audiobookID: folderURL.absoluteString)
        switch CardTapDecision.make(time: time) {
        case .seekAndPlay(let seconds):
            model.seek(toSeconds: seconds)
            if !model.isPlaying { model.play() }
        case .noTime:
            Haptic.play(.light)  // un-narrated / un-aligned block — acknowledge the tap
        }
        viewModel?.activeBlockID = blockID  // highlight + scroll the tapped card either way
        model.readerCaptureAnchorBlockID = blockID
    }

    /// Seek-only (no auto-play) — used by TOC navigation, which should jump without
    /// starting playback. Upgraded from the bare engine seek to the canonical
    /// user-seek so progress/artwork refresh and a playing session resumes there.
    private func seekToBlock(_ blockID: String) {
        guard let vm = viewModel else { return }
        let audiobookID = folderURL.absoluteString
        if let time = vm.audioStartTime(for: blockID, audiobookID: audiobookID), time >= 0 {
            model.seek(toSeconds: time)
        }
    }

    private func seekToBlockAndScroll(_ blockID: String) {
        // Attempt to seek audio if the block has a timestamp
        seekToBlock(blockID)

        // Immediately set the active block ID so the UI scrolls to it
        // even if the block doesn't have an audio timestamp yet.
        viewModel?.activeBlockID = blockID
        model.readerCaptureAnchorBlockID = blockID
    }

    private func configureReaderCaptureActions() {
        model.readerCaptureAnchorBlockID = viewModel?.activeBlockID
        model.readerAddNoteAction = { beginReaderNote() }
        model.readerToggleVoiceMemoAction = { toggleReaderVoiceMemo() }
    }

    private func clearReaderCaptureActions() {
        cancelReaderMemoIfNeeded()
        model.readerCaptureAnchorBlockID = nil
        model.readerAddNoteAction = nil
        model.readerToggleVoiceMemoAction = nil
    }

    private func currentReaderCaptureBlockID() -> String? {
        viewModel?.activeBlockID ?? model.readerCaptureAnchorBlockID
    }

    private func beginReaderNote() {
        guard let blockID = currentReaderCaptureBlockID() else { return }
        composingNoteBlockID = blockID
        readerNoteText = ""
        isComposingReaderNote = true
    }

    private func cancelReaderNote() {
        readerNoteText = ""
        composingNoteBlockID = nil
        isComposingReaderNote = false
    }

    private func saveReaderNote() {
        let text = readerNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let blockID = composingNoteBlockID, !text.isEmpty else {
            cancelReaderNote()
            return
        }
        viewModel?.addNote(text: text, atBlockID: blockID)
        cancelReaderNote()
    }

    private func toggleReaderVoiceMemo() {
        if model.isReaderVoiceMemoRecording {
            stopReaderMemo()
        } else {
            startReaderMemo()
        }
    }

    private func startReaderMemo() {
        guard let blockID = currentReaderCaptureBlockID() else { return }
        do {
            try memoRecorder.start()
            recordingMemoBlockID = blockID
            model.readerCaptureAnchorBlockID = blockID
            model.isReaderVoiceMemoRecording = true
        } catch {
            recordingMemoBlockID = nil
            model.isReaderVoiceMemoRecording = false
            logger.error("Failed to start reader memo: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopReaderMemo() {
        defer {
            recordingMemoBlockID = nil
            model.isReaderVoiceMemoRecording = false
        }
        guard let result = memoRecorder.stop(),
            let blockID = recordingMemoBlockID ?? currentReaderCaptureBlockID()
        else { return }
        viewModel?.addVoiceMemo(fileURL: result.url, duration: result.duration, atBlockID: blockID)
    }

    private func cancelReaderMemoIfNeeded() {
        if memoRecorder.isRecording {
            memoRecorder.cancel()
        }
        recordingMemoBlockID = nil
        model.isReaderVoiceMemoRecording = false
    }

    /// Renders a compact instructional banner.
    @ViewBuilder
    private func hintBanner(
        icon: String, message: String, dismissible: Bool, onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if dismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss hint")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    func saveImageToCameraRoll(block: EPubBlockRecord) {
        guard let imagePath = block.imagePath else { return }
        var url = URL(fileURLWithPath: imagePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let filename = url.lastPathComponent
            let dirName = url.deletingLastPathComponent().lastPathComponent
            let appSupport = FileLocations.applicationSupportDirectory
            url = appSupport.appendingPathComponent("EPUBAssets").appendingPathComponent(dirName)
                .appendingPathComponent(filename)
        }
        if let image = UIImage(contentsOfFile: url.path) {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }
    }

    @ViewBuilder
    private var localUtilitiesRow: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in book...", text: $model.epubSearchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !model.epubSearchText.isEmpty {
                    Button {
                        model.epubSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 10))

            Button {
                model.epubScrollToActiveTrigger += 1
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemBackground), in: Circle())
            .accessibilityLabel(Text("Scroll to current playback position"))

            Button {
                model.showReaderTOC = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16))
            }
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemBackground), in: Circle())
            .accessibilityLabel(Text("Table of Contents"))

            Button {
                model.showReaderSettings = true
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 16))
            }
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemBackground), in: Circle())
            .accessibilityLabel(Text("Reader settings"))

            Button {
                showSessions = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16))
            }
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemBackground), in: Circle())
            .accessibilityLabel(Text("Listening sessions"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

private struct ReaderNoteComposerSheet: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("New Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: onSave)
                            .disabled(!canSave)
                    }
                }
        }
    }
}

/// Sheet showing the EPUB's Table of Contents (sections/headings) for navigation.
struct EPUBTOCSheet: View {
    let sections: [ReaderCardSection]
    /// Publisher-declared TOC entries (NCX/nav). When present they define the
    /// tree; heading inference is only a fallback for books without one.
    var tocEntries: [EPubTOCEntryRecord] = []
    let activeBlockID: String?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var expandedChapters: Set<String> = []

    private var chapters: [TOCNode] {
        var allBlocks: [EPubBlockRecord] = []
        for section in sections {
            for item in section.items {
                if case .block(let b) = item {
                    allBlocks.append(b)
                }
            }
        }
        return TOCTreeBuilder.build(from: allBlocks, tocEntries: tocEntries)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chapters) { chapter in
                    TOCNodeView(
                        node: chapter,
                        activeBlockID: activeBlockID,
                        onSelect: { blockID in
                            onSelect(blockID)
                            dismiss()
                        },
                        expandedNodes: $expandedChapters
                    )
                }
            }
            .listStyle(.plain)
            .navigationTitle("Table of Contents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let activeID = activeBlockID {
                    func expandPath(for nodes: [TOCNode], path: [String]) -> Bool {
                        for node in nodes {
                            let newPath = path + [node.id]
                            if node.blockID == activeID
                                || expandPath(for: node.children, path: newPath)
                            {
                                expandedChapters.formUnion(newPath)
                                return true
                            }
                        }
                        return false
                    }
                    _ = expandPath(for: chapters, path: [])
                }
            }
        }
    }
}

struct TOCNodeView: View {
    let node: TOCNode
    let activeBlockID: String?
    let onSelect: (String) -> Void
    @Binding var expandedNodes: Set<String>

    var body: some View {
        if node.children.isEmpty {
            TOCRow(title: node.title, isActive: node.blockID == activeBlockID) {
                onSelect(node.blockID)
            }
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedNodes.contains(node.id) },
                    set: { isExp in
                        if isExp {
                            expandedNodes.insert(node.id)
                        } else {
                            expandedNodes.remove(node.id)
                        }
                    }
                )
            ) {
                ForEach(node.children) { child in
                    TOCNodeView(
                        node: child,
                        activeBlockID: activeBlockID,
                        onSelect: onSelect,
                        expandedNodes: $expandedNodes
                    )
                }
            } label: {
                TOCRow(title: node.title, isActive: node.blockID == activeBlockID) {
                    onSelect(node.blockID)
                }
            }
        }
    }
}

struct TOCRow: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(
                        isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary)
                    )
                    .lineLimit(2)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption.bold())
                }
            }
        }
        .buttonStyle(.plain)
    }
}
