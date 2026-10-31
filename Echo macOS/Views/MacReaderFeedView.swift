// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI
import os.log

/// Manual per-block alignment actions offered in the reader's right-click menu,
/// mirroring the iOS reader's alignment context menu. The work is done by the
/// shared, macOS-clean `AlignmentService`.
enum MacReaderAlignmentAction {
    case alignToNow
    case alignTo5sAgo
    case notInAudio
    case hideChapter
    case eraseAnchor
    case resetAlignment
}

/// Center pane — scrollable card feed of EPUB blocks matching the iOS reader.
///
/// Renders heading, paragraph, and image cards from `EPubBlockRecord` in
/// reading order. Auto-scrolls to the block currently playing, if alignment
/// data is available.
struct MacReaderFeedView: View {
    @Environment(MacPlayerModel.self) private var player
    @Environment(DatabaseService.self) private var dbService
    @Environment(SettingsManager.self) private var settings
    /// Watched only to know when the batch queue goes idle, which is when a
    /// just-finished alignment makes the header badge stale.
    @Environment(MacBatchProcessingService.self) private var batchService
    @State private var blocks: [EPubBlockRecord] = []
    @State private var currentBlockID: String?
    @State private var isLoading = true
    /// Phase 5 (macOS parity): which chapter is currently expanded (nil = all collapsed).
    @State private var openChapterKey: Int?
    /// Chapter indices that actually have audio (honest has-audio styling).
    @State private var chaptersWithAudio: Set<Int> = []
    /// Display title per chapter, from the publisher TOC then audio metadata
    /// (`ChapterTitleResolver`, shared with the iOS reader). Absent keys fall
    /// back to the chapter's own first heading below.
    @State private var chapterTitles: [Int: String] = [:]
    /// Tracks the previously-playing chapter so auto-expand only fires on change.
    @State private var lastPlayingChapterKey: Int?
    /// Timeline rows (audio range → block, with chapter index) for the loaded
    /// book. Resolution scopes by chapter to the currently-playing track via the
    /// shared `ReaderActiveBlockResolver`, so per-track time collisions across
    /// multiple files no longer pin the highlight to the first track.
    @State private var timelineCache: [ReaderActiveBlockResolver.TimelineRow] = []
    /// Per-word audio ranges for the loaded book, ordered by audio start time
    /// (the reader-cache order). Fed to `ReaderActiveBlockResolver.activeWord`
    /// for karaoke word highlighting within the active block.
    @State private var wordCache: [ReaderActiveBlockResolver.WordRow] = []
    /// Per-block index over `wordCache`, rebuilt alongside it
    /// so the 12.5 Hz tick in `trackCurrentBlock()` no longer linear-scans the
    /// whole book's word rows.
    @State private var wordIndex = ReaderActiveBlockResolver.WordIndex(rows: [])
    /// (blockID, wordIndex) of the currently spoken word, for karaoke highlight.
    @State private var activeWord: (blockID: String, index: Int)?
    /// Whether the loaded book has source-PDF page data (`pdf_block_page` rows) —
    /// gates the Reflow/Page toggle. False for EPUB-sourced or unaligned books.
    @State private var hasPDFPages = false
    /// True shows the page-faithful `MacPDFReaderView` instead of the reflowed
    /// block feed below.
    @State private var showingPageView = false
    /// Whether this book's text is genuinely aligned to its audio, surfaced in
    /// the header. Recomputed on load and whenever the batch queue finishes a
    /// book, since a completed alignment changes the answer without touching
    /// any of the reader's other reload triggers.
    @State private var alignmentSummary: BookAlignmentSummary = .empty

    @State private var chapterGroups:
        [(key: Int, title: String, hasAudio: Bool, blocks: [EPubBlockRecord])] = []
    @State private var chapterByBlockID: [String: Int] = [:]
    @State private var timelineIndex = ReaderActiveBlockResolver.TimelineIndex(rows: [])
    @State private var loadRevision = 0
    @State private var loadedBookID: String?

    private nonisolated struct ReaderSnapshot: Sendable {
        let blocks: [EPubBlockRecord]
        let playback: ReaderPlaybackSnapshot
        let titles: [Int: String]
        let audioChapters: Set<Int>
        let hasPDFPages: Bool
        let summary: BookAlignmentSummary
        let groups: [(key: Int, title: String, hasAudio: Bool, blocks: [EPubBlockRecord])]
        let chapterByBlockID: [String: Int]
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if showingPageView, hasPDFPages {
                MacPDFReaderView()
            } else if isLoading {
                Spacer()
                ProgressView("Loading reader…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if blocks.isEmpty {
                Spacer()
                if player.audiobookID == nil {
                    // Idle (no book open): nudge toward on-device narration —
                    // the primary way the Mac gets spoken audio for a text-only
                    // book. The button routes to the same "Narrate Documents…"
                    // picker as the Batch menu (handled in Echo_macOSApp).
                    NarrationNudgeView(
                        title: "Narrate a Document",
                        message:
                            "Got an EPUB, PDF, or text file with no audiobook? Echo can speak it on-device so you can study hands-free.",
                        buttonTitle: "Choose Document to Narrate\u{2026}",
                        onListen: {
                            NotificationCenter.default.post(
                                name: .requestNarrateEPUBs, object: nil)
                        }
                    )
                    .frame(maxWidth: 420)
                    .padding()
                } else {
                    ContentUnavailableView(
                        "No EPUB Content",
                        systemImage: "book",
                        description: Text("Import an EPUB to see the reader here.")
                    )
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(chapterGroups, id: \.key) { group in
                                // Collapsed chapter header row (always visible, tappable).
                                Button {
                                    openChapterKey = FeedAccordion.toggled(
                                        current: openChapterKey, tapped: group.key)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(
                                            systemName: openChapterKey == group.key
                                                ? "chevron.down" : "chevron.right"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        Text(group.title)
                                            .customFont(.headline, appFont: settings.appFont)
                                            .foregroundStyle(
                                                group.hasAudio ? .primary : .secondary)
                                        if !group.hasAudio {
                                            Text("Text only")
                                                .customFont(.caption2, appFont: settings.appFont)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // Expanded content (only the open chapter).
                                if openChapterKey == group.key {
                                    ForEach(group.blocks, id: \.id) { block in
                                        MacBlockCardView(
                                            block: block,
                                            appFont: settings.appFont,
                                            isActive: block.id == currentBlockID,
                                            activeWordIndex: block.id == currentBlockID
                                                ? activeWord?.index : nil,
                                            onTap: { seekToBlock(block.id) },
                                            onAlignmentAction: { performAlignment($0, on: $1) }
                                        )
                                        .equatable()
                                        .id(block.id)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    .onChange(of: currentBlockID) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300)
        .task(id: player.audiobookID) {
            await loadBlocks()
        }
        .task {
            await trackCurrentBlock()
        }
        .onChange(of: player.documentIngestionTrigger) { _, _ in
            // Transcript materialization creates epub_block rows for the current
            // book without changing currentURL; reload so read-along appears.
            Task { await loadBlocks() }
        }
        // A batch alignment writes anchors and rebuilds the timeline for a book
        // that may already be open, without touching currentURL or the
        // ingestion trigger. Re-read the verdict when the queue falls idle so
        // the badge doesn't keep claiming "Estimated only" after the run that
        // fixed it. Cheap enough to do unconditionally: three indexed COUNTs.
        .onChange(of: batchService.activity == nil) { _, isIdle in
            guard isIdle, let audiobookID = player.audiobookID else { return }
            Task { await refreshAlignmentSummary(audiobookID: audiobookID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) { note in
            guard let ingestedID = note.userInfo?["audiobookID"] as? String,
                ingestedID == player.audiobookID
            else { return }
            Task { await refreshAlignmentSummary(audiobookID: ingestedID) }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Reader")
                .customFont(.headline, appFont: settings.appFont)

            MacAlignmentBadge(summary: alignmentSummary)

            Spacer()
            if hasPDFPages {
                Picker("View", selection: $showingPageView) {
                    Text("Reflow").tag(false)
                    Text("Page").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            Text("\(blocks.count) blocks")
                .customFont(.caption, appFont: settings.appFont)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Load blocks

    private func loadBlocks() async {
        loadRevision &+= 1
        let revision = loadRevision
        let bookID = player.audiobookID
        isLoading = true
        defer { if revision == loadRevision { isLoading = false } }
        guard let bookID else {
            clearReader()
            return
        }
        if loadedBookID != bookID { clearReader() }
        let writer = dbService.writer
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Self.buildSnapshot(audiobookID: bookID, writer: writer)
            }.value
            guard !Task.isCancelled, revision == loadRevision, player.audiobookID == bookID else {
                return
            }
            if loadedBookID != bookID {
                openChapterKey = nil
                lastPlayingChapterKey = nil
                currentBlockID = nil
                activeWord = nil
                showingPageView = false
            }
            loadedBookID = bookID
            blocks = snapshot.blocks
            chapterTitles = snapshot.titles
            chaptersWithAudio = snapshot.audioChapters
            hasPDFPages = snapshot.hasPDFPages
            if !hasPDFPages { showingPageView = false }
            timelineCache = snapshot.playback.timeline
            timelineIndex = snapshot.playback.timelineIndex
            wordCache = snapshot.playback.words
            wordIndex = snapshot.playback.wordIndex
            alignmentSummary = snapshot.summary
            chapterGroups = snapshot.groups
            chapterByBlockID = snapshot.chapterByBlockID
        } catch {
            guard !Task.isCancelled, revision == loadRevision, player.audiobookID == bookID else {
                return
            }
            clearReader()
        }
    }

    private func clearReader() {
        blocks = []
        chapterGroups = []
        chapterTitles = [:]
        chapterByBlockID = [:]
        chaptersWithAudio = []
        timelineCache = []
        timelineIndex = .init(rows: [])
        wordCache = []
        wordIndex = .init(rows: [])
        currentBlockID = nil
        activeWord = nil
        openChapterKey = nil
        lastPlayingChapterKey = nil
        hasPDFPages = false
        showingPageView = false
        alignmentSummary = .empty
        loadedBookID = nil
    }

    private nonisolated static func buildSnapshot(audiobookID: String, writer: any DatabaseWriter)
        throws -> ReaderSnapshot
    {
        let blocks = try EPubBlockDAO(db: writer).visibleBlocks(for: audiobookID)
        let chapterTitles = resolveChapterTitles(
            blocks: blocks, audiobookID: audiobookID, db: writer)
        let chaptersWithAudio = try ChapterAudioStatusResolver(db: writer).chaptersWithAudio(
            audiobookID: audiobookID)
        let grouped = Dictionary(grouping: blocks, by: { $0.chapterIndex ?? -1 })
        let groups = grouped.keys.sorted().map { key in
            let chapterBlocks = grouped[key] ?? []
            // Prefer what the publisher declared. Falling straight to "the first
            // heading" names a Calibre-converted chapter after its number alone
            // (`<h1>2</h1>` precedes `<h1>COURTROOM 3: …</h1>`) and names any
            // chapter opening on a recurring sidebar after the sidebar.
            let title =
                chapterTitles[key]
                ?? chapterBlocks.first(where: {
                    $0.blockKind == EPubBlockRecord.Kind.heading.rawValue
                })?.text
                ?? chapterBlocks.first?.text
                ?? "Chapter \(key + 1)"
            return (
                key: key, title: title, hasAudio: chaptersWithAudio.contains(key),
                blocks: chapterBlocks
            )
        }
        return ReaderSnapshot(
            blocks: blocks, playback: try .load(audiobookID: audiobookID, db: writer),
            titles: chapterTitles, audioChapters: chaptersWithAudio,
            hasPDFPages: try !PDFBlockPageDAO(db: writer).rows(for: audiobookID).isEmpty,
            summary: try BookAlignmentSummary.load(audiobookID: audiobookID, db: writer),
            groups: groups,
            chapterByBlockID: Dictionary(
                uniqueKeysWithValues: blocks.compactMap {
                    block in block.chapterIndex.map { (block.id, $0) }
                }))
    }

    private func refreshAlignmentSummary(audiobookID: String) async {
        let writer = dbService.writer
        let revision = loadRevision
        let summary = await Task.detached(priority: .utility) {
            (try? BookAlignmentSummary.load(audiobookID: audiobookID, db: writer)) ?? .empty
        }.value
        guard !Task.isCancelled, revision == loadRevision, player.audiobookID == audiobookID else {
            return
        }
        alignmentSummary = summary
    }

    /// Chapter display titles for the loaded book, via the shared
    /// `ChapterTitleResolver` the iOS reader uses — publisher TOC label for the
    /// entry anchored to each chapter's first block, else the audio chapter's
    /// own title. `blocks` must already be in reading order.
    private nonisolated static func resolveChapterTitles(
        blocks: [EPubBlockRecord], audiobookID: String, db: any DatabaseWriter
    ) -> [Int: String] {
        var firstBlockIDByChapter: [Int: String] = [:]
        for block in blocks {
            guard let chapter = block.chapterIndex, firstBlockIDByChapter[chapter] == nil else {
                continue
            }
            firstBlockIDByChapter[chapter] = block.id
        }
        let tocEntries = (try? EPubTOCEntryDAO(db: db).entries(for: audiobookID)) ?? []
        let audioChapters = (try? ChapterDAO(db: db).chapters(for: audiobookID)) ?? []
        // Chapter index is the audio chapter's position, matching how the
        // importer assigns `epub_block.chapter_index`.
        let audioTitles = Dictionary(
            audioChapters.enumerated().map { ($0.offset, $0.element.title) },
            uniquingKeysWith: { first, _ in first })
        return ChapterTitleResolver.titles(
            firstBlockIDByChapter: firstBlockIDByChapter,
            tocEntries: tocEntries,
            audioChapterTitles: audioTitles)
    }

    /// EPUB chapter indices in the currently-playing track. macOS has no narration
    /// and no M4B aggregation, so it routes through the same shared
    /// `ReaderActiveBlockResolver.trackChapterScope` with `playingChapterIndex: nil`
    /// and `isMultiM4B: false`: a single track means one continuous axis → `nil`
    /// (no scoping, strict legacy behavior); multiple tracks (MP3 folder) map 1:1
    /// track→chapter → `{currentTrackIndex}`. Sharing the one branch table with iOS
    /// keeps the two readers from drifting.
    private var currentTrackChapterIndices: Set<Int>? {
        ReaderActiveBlockResolver.trackChapterScope(
            trackCount: player.tracks.count,
            isMultiM4B: false,
            currentIndex: player.currentTrackIndex,
            playingChapterIndex: nil)
    }

    /// Tapping a paragraph card seeks to it AND starts playing (parity with iOS).
    /// Uses the shared `timelineCache` built during load; an un-timed block is a
    /// no-op (no audio yet — macOS has no haptics for feedback).
    private func seekToBlock(_ blockID: String) {
        let time = timelineCache.first(where: { $0.blockID == blockID })?.start
        switch CardTapDecision.make(time: time) {
        case .seekAndPlay(let seconds):
            player.seek(to: seconds)
            if !player.isPlaying { player.play() }
        case .noTime:
            break
        }
    }

    /// Applies a manual alignment edit via the shared `AlignmentService`, then
    /// reloads the feed so the new anchor/timeline is reflected. Mirrors the iOS
    /// reader's alignment context menu. A bad anchor no longer forces a full batch
    /// DTW re-run on macOS.
    private func performAlignment(_ action: MacReaderAlignmentAction, on block: EPubBlockRecord) {
        guard let audiobookID = player.audiobookID else { return }
        let writer = dbService.writer
        let now = player.currentTime
        Task {
            do {
                let service = AlignmentService(db: writer, audiobookID: audiobookID)
                switch action {
                case .alignToNow:
                    try service.moveBlockToCurrentTime(blockID: block.id, time: now)
                case .alignTo5sAgo:
                    try service.moveBlockToCurrentTime(blockID: block.id, time: max(0, now - 5))
                case .notInAudio:
                    try service.hideBlock(blockID: block.id, reason: "manual")
                case .hideChapter:
                    if let chapterIndex = block.chapterIndex {
                        try service.hideChapter(chapterIndex: chapterIndex, reason: "manual")
                    }
                case .eraseAnchor:
                    try service.eraseAnchor(blockID: block.id)
                case .resetAlignment:
                    try service.resetAlignment()
                }
                await loadBlocks()
            } catch {
                Logger(subsystem: "com.echo.audiobooks", category: "MacReader")
                    .error(
                        "Manual alignment failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Periodically resolves the block at the current playback time so the reader
    /// can highlight and auto-scroll to the active block. Resolution is delegated
    /// to the shared `ReaderActiveBlockResolver` (the same helper iOS uses) and is
    /// scoped to the currently-playing track, so per-track time collisions across
    /// multiple files no longer pin the highlight to the first track.
    private func trackCurrentBlock() async {
        var previousTime: TimeInterval?
        var previousScope: Set<Int>?
        var previousRevision = -1
        while !Task.isCancelled {
            let time = player.currentTime
            let scope = currentTrackChapterIndices
            if player.isPlaying, time > 0 {
                if time == previousTime, scope == previousScope, previousRevision == loadRevision {
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                previousTime = time
                previousScope = scope
                previousRevision = loadRevision
                currentBlockID = ReaderActiveBlockResolver.activeBlockID(
                    in: timelineIndex,
                    time: time,
                    currentTrackChapterIndices: currentTrackChapterIndices
                )
                if let idx = ReaderActiveBlockResolver.activeWord(
                    in: wordIndex,
                    time: player.currentTime,
                    activeBlockID: currentBlockID
                ) {
                    activeWord = (blockID: currentBlockID ?? "", index: idx)
                } else {
                    activeWord = nil
                }
                // Phase 5: auto-expand the chapter that is currently playing.
                if let playingID = currentBlockID,
                    let playingChapter = chapterByBlockID[playingID]
                {
                    openChapterKey = FeedAccordion.autoExpand(
                        current: openChapterKey,
                        playingChapterKey: playingChapter,
                        lastPlayingChapterKey: lastPlayingChapterKey
                    )
                    lastPlayingChapterKey = playingChapter
                }
            } else {
                previousTime = nil
                currentBlockID = nil
                activeWord = nil
            }
            // ~12 Hz while playing for smooth karaoke, 0.5 s when paused so the
            // block poll stays cheap when nothing is moving.
            try? await Task.sleep(for: player.isPlaying ? .milliseconds(80) : .milliseconds(500))
        }
    }
}

// MARK: - Block Card Views

private struct MacBlockCardView: View, Equatable {
    @Environment(MacPlayerModel.self) private var player
    let block: EPubBlockRecord
    let appFont: String
    let isActive: Bool
    /// Word index to karaoke-highlight, or nil when this card isn't the active
    /// block (the parent passes nil for inactive cards, so only the active card
    /// re-renders as the spoken word advances).
    var activeWordIndex: Int?
    var onTap: (() -> Void)?
    /// Manual alignment menu callback (action, this block). nil hides the menu.
    var onAlignmentAction: ((MacReaderAlignmentAction, EPubBlockRecord) -> Void)?

    // Equatable so the polled reader feed re-evaluates only the cards that
    // actually changed (§8.2). Rendering depends on block + isActive + the
    // highlighted word index, so a moving karaoke highlight updates only the
    // active card.
    nonisolated static func == (lhs: MacBlockCardView, rhs: MacBlockCardView) -> Bool {
        lhs.block == rhs.block && lhs.appFont == rhs.appFont && lhs.isActive == rhs.isActive
            && lhs.activeWordIndex == rhs.activeWordIndex
    }

    var body: some View {
        if block.blockKind == EPubBlockRecord.Kind.code.rawValue {
            // Keep the code text outside a Button so macOS text selection works.
            // Seeking remains available as an explicit control in `codeCard`.
            cardContent
        } else if let onTap {
            Button(action: onTap) {
                cardContent
            }
            .buttonStyle(.plain)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        blockContent
            .padding(.horizontal)
            .padding(.vertical, 6)
            // One continuous page, as on iPhone: the block being read gets a
            // soft rounded wash in the accent (cover) colour instead of a bar.
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .contextMenu { alignmentMenu }
    }

    /// Right-click alignment menu — parity with the iOS reader's per-block menu.
    @ViewBuilder
    private var alignmentMenu: some View {
        if let onAlignmentAction {
            Button("Align to Now") { onAlignmentAction(.alignToNow, block) }
            Button("Align to 5s Ago") { onAlignmentAction(.alignTo5sAgo, block) }
            Divider()
            Button("Not in Audio (This Paragraph)") { onAlignmentAction(.notInAudio, block) }
            Button("Not in Audio (Whole Chapter)") { onAlignmentAction(.hideChapter, block) }
            Divider()
            Button("Erase Anchor") { onAlignmentAction(.eraseAnchor, block) }
            Button("Reset Alignment\u{2026}", role: .destructive) {
                onAlignmentAction(.resetAlignment, block)
            }
        }
    }

    @ViewBuilder
    private var blockContent: some View {
        switch block.blockKind {
        case EPubBlockRecord.Kind.heading.rawValue:
            headingCard
        case EPubBlockRecord.Kind.image.rawValue:
            imageCard
        case EPubBlockRecord.Kind.code.rawValue:
            codeCard
        default:
            paragraphCard
        }
    }

    // MARK: Heading Card

    private var headingCard: some View {
        Text(highlightedText(block.text ?? "", activeWordIndex: activeWordIndex))
            .customFont(.title3, weight: .semibold, appFont: appFont)
            .foregroundStyle(resolvedColor ?? Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: Paragraph Card

    private var paragraphCard: some View {
        Text(highlightedText(block.text ?? "", activeWordIndex: activeWordIndex))
            .customFont(.body, appFont: appFont)
            .foregroundStyle(resolvedColor ?? Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(4)
    }

    // MARK: Code Card

    private var codeCard: some View {
        VStack(alignment: .leading) {
            HStack {
                if let language = block.codeLanguage?.trimmingCharacters(
                    in: .whitespacesAndNewlines), !language.isEmpty
                {
                    Text(language.uppercased())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onTap {
                    Button("Seek to code listing", systemImage: "play.fill", action: onTap)
                        .labelStyle(.iconOnly)
                }
            }

            ScrollView(.horizontal) {
                Text(block.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel(Text("Code listing"))
            .accessibilityValue(Text(block.text ?? ""))
        }
    }

    // MARK: Image Card

    private var imageCard: some View {
        Group {
            if let imagePath = block.imagePath, !imagePath.isEmpty {
                if let resolvedURL = resolveImageURL(imagePath: imagePath),
                    let nsImage = NSImage(contentsOf: resolvedURL)
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text("[Image: \(block.imagePath ?? "unknown")]")
                        .customFont(.caption, appFont: appFont)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("[Image]")
                    .customFont(.caption, appFont: appFont)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    // MARK: Helpers

    /// Returns the block text with the active karaoke word bolded and tinted.
    ///
    /// Highlighting is *positional*, not substring-based: the word at
    /// `activeWordIndex` is located by its character range in the text rather
    /// than by searching for its string value. This mirrors the iOS sibling
    /// (`ParagraphCardCell`), which routes through the same shared
    /// `WordTokenizer` ranges so repeated words don't break a naive substring
    /// search. A substring search would mis-fire for short, common words that
    /// also appear *inside* earlier words — e.g. "is" matching the "is" inside
    /// "This" — which is pervasive in prose. Word boundaries come from
    /// `WordTokenizer` (split on any Unicode whitespace, `Character.isWhitespace`),
    /// the same definition the `WordTimingInterpolator` uses to assign `wordIndex`.
    /// Because that matches `collapsedWhitespace()`, feeding raw `block.text` here
    /// yields the same indices the materializer assigned, so index N maps to
    /// exactly the rendered word it timed.
    private func highlightedText(_ text: String, activeWordIndex: Int?) -> AttributedString {
        let attributed = AttributedString(text)
        guard let activeWordIndex, activeWordIndex >= 0 else { return attributed }
        let ranges = WordTokenizer.wordRanges(in: text)
        guard activeWordIndex < ranges.count else { return attributed }
        // Map the word's character range in `text` onto the AttributedString.
        guard
            let lower = AttributedString.Index(
                ranges[activeWordIndex].lowerBound, within: attributed),
            let upper = AttributedString.Index(
                ranges[activeWordIndex].upperBound, within: attributed)
        else { return attributed }
        var result = attributed
        // Color/background only — NO font-weight change. A weight swap reflows the
        // line on every word step (parity with iOS ParagraphCardCell).
        result[lower..<upper].backgroundColor = .accentColor.opacity(0.25)
        return result
    }

    private var resolvedColor: Color? {
        guard let hex = block.chapterThemeColor ?? block.cardColor else { return nil }
        return Color(hex: hex)
    }

    /// Resolves an EPUB image path relative to the audiobook's asset directory.
    private func resolveImageURL(imagePath: String) -> URL? {
        guard let folderURL = player.folderURL else { return nil }
        let assetsDir = SafeFileName.fromAudiobookID(folderURL.absoluteString)
        let base =
            folderURL
            .deletingLastPathComponent()
            .appendingPathComponent(assetsDir)
            .appendingPathComponent("EPUBAssets")
        let url = base.appendingPathComponent(imagePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// Color(hex:) is now provided by EchoCore/Views/ReaderSettingsSheet.swift
