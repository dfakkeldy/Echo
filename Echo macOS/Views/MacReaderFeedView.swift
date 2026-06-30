// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI

/// Center pane — scrollable card feed of EPUB blocks matching the iOS reader.
///
/// Renders heading, paragraph, and image cards from `EPubBlockRecord` in
/// reading order. Auto-scrolls to the block currently playing, if alignment
/// data is available.
struct MacReaderFeedView: View {
    @Environment(MacPlayerModel.self) private var player
    @Environment(DatabaseService.self) private var dbService
    @Environment(SettingsManager.self) private var settings
    @State private var blocks: [EPubBlockRecord] = []
    @State private var currentBlockID: String?
    @State private var isLoading = true
    /// Phase 5 (macOS parity): which chapter is currently expanded (nil = all collapsed).
    @State private var openChapterKey: Int?
    /// Chapter indices that actually have audio (honest has-audio styling).
    @State private var chaptersWithAudio: Set<Int> = []
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
    /// (blockID, wordIndex) of the currently spoken word, for karaoke highlight.
    @State private var activeWord: (blockID: String, index: Int)?

    /// Blocks grouped into one entry per chapter, in reading order.
    /// Uses `$0.chapterIndex ?? -1` because `EPubBlockRecord.chapterIndex` is `Int?`;
    /// -1 is the front-matter convention already used by `ChapterAudioStatusResolver`.
    private var chapterGroups:
        [(key: Int, title: String, hasAudio: Bool, blocks: [EPubBlockRecord])]
    {
        let grouped = Dictionary(grouping: blocks, by: { $0.chapterIndex ?? -1 })
        return grouped.keys.sorted().map { key in
            let chapterBlocks = grouped[key] ?? []
            // Use the first heading block's text as the chapter title; fall back to
            // first block text, then a generic label.
            let title =
                chapterBlocks.first(where: { $0.blockKind == EPubBlockRecord.Kind.heading.rawValue }
                )?.text
                ?? chapterBlocks.first?.text
                ?? "Chapter \(key + 1)"
            return (
                key: key, title: title, hasAudio: chaptersWithAudio.contains(key),
                blocks: chapterBlocks
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Loading reader…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if blocks.isEmpty {
                Spacer()
                if player.audiobookID == nil {
                    // Idle (no book open): nudge toward on-device narration —
                    // the primary way the Mac gets spoken audio for a text-only
                    // EPUB. The button routes to the same "Narrate EPUB(s)…"
                    // picker as the Batch menu (handled in Echo_macOSApp).
                    NarrationNudgeView(
                        title: "Narrate an EPUB",
                        message:
                            "Got a book with no audiobook? Echo can speak it on-device so you can study hands-free.",
                        buttonTitle: "Choose EPUB to Narrate\u{2026}",
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
                                            onTap: { seekToBlock(block.id) }
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
        .task {
            await loadBlocks()
        }
        .task {
            await trackCurrentBlock()
        }
        .onChange(of: player.currentURL) { _, _ in
            Task { await loadBlocks() }
        }
        .onChange(of: player.documentIngestionTrigger) { _, _ in
            // Transcript materialization creates epub_block rows for the current
            // book without changing currentURL; reload so read-along appears.
            Task { await loadBlocks() }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Reader")
                .customFont(.headline, appFont: settings.appFont)
            Spacer()
            Text("\(blocks.count) blocks")
                .customFont(.caption, appFont: settings.appFont)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Load blocks

    private func loadBlocks() async {
        isLoading = true
        defer { isLoading = false }

        // Reset auto-expand state on book switch so a new book's first playing
        // chapter is never suppressed by a stale key from the previous book.
        lastPlayingChapterKey = nil

        guard let audiobookID = player.audiobookID else {
            blocks = []
            timelineCache = []
            wordCache = []
            return
        }

        do {
            let result = try await dbService.writer.read { db in
                try EPubBlockRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .filter(Column("is_hidden") == false)
                    .order(Column("sequence_index"))
                    .fetchAll(db)
            }
            blocks = result
            // Phase 5: honest per-chapter has-audio for the accordion.
            let resolver = ChapterAudioStatusResolver(db: dbService.writer)
            chaptersWithAudio = (try? resolver.chaptersWithAudio(audiobookID: audiobookID)) ?? []
            timelineCache = try await loadTimelineCache(audiobookID: audiobookID)
            // Per-word timings (Phase A) for karaoke; absent on unaligned books → [].
            let words = try WordTimingDAO(db: dbService.writer).words(forAudiobook: audiobookID)
            wordCache = words.map {
                (
                    start: $0.audioStartTime, end: $0.audioEndTime,
                    blockID: $0.epubBlockID, wordIndex: $0.wordIndex
                )
            }
        } catch {
            blocks = []
            timelineCache = []
            wordCache = []
        }
    }

    /// Builds the audio-range → block timeline cache, LEFT JOINing `epub_block`
    /// for each block's `chapter_index`, so active-block resolution can be scoped
    /// to the currently-playing track. Ordered by `audio_start_time` to match the
    /// iOS reader's cache and the resolver's binary-search (unscoped) path.
    private func loadTimelineCache(audiobookID: String) async throws
        -> [ReaderActiveBlockResolver.TimelineRow]
    {
        let rows: [Row] = try dbService.writer.read { db in
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id,
                           ti.segment_key, eb.chapter_index
                    FROM timeline_item ti
                    LEFT JOIN epub_block eb ON eb.id = ti.epub_block_id
                    WHERE ti.audiobook_id = ? AND ti.epub_block_id IS NOT NULL AND ti.audio_start_time >= 0
                    ORDER BY ti.audio_start_time
                    """,
                arguments: [audiobookID]
            )
        }

        var cache: [ReaderActiveBlockResolver.TimelineRow] = []
        for (i, row) in rows.enumerated() {
            guard let start: TimeInterval = row["audio_start_time"],
                let blockID: String = row["epub_block_id"]
            else { continue }
            let end: TimeInterval
            if let explicitEnd: TimeInterval = row["audio_end_time"] {
                end = explicitEnd
            } else if i + 1 < rows.count,
                let nextStart: TimeInterval = rows[i + 1]["audio_start_time"]
            {
                end = nextStart
            } else {
                end = start + 3600  // Large fallback for the last item
            }
            let chapterIndex: Int? = row["chapter_index"]
            let segmentKey: String? = row["segment_key"]
            cache.append((start, end, blockID, chapterIndex, segmentKey))
        }
        return cache
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

    /// Periodically resolves the block at the current playback time so the reader
    /// can highlight and auto-scroll to the active block. Resolution is delegated
    /// to the shared `ReaderActiveBlockResolver` (the same helper iOS uses) and is
    /// scoped to the currently-playing track, so per-track time collisions across
    /// multiple files no longer pin the highlight to the first track.
    private func trackCurrentBlock() async {
        while !Task.isCancelled {
            if player.isPlaying, player.currentTime > 0 {
                currentBlockID = ReaderActiveBlockResolver.activeBlockID(
                    in: timelineCache,
                    time: player.currentTime,
                    currentTrackChapterIndices: currentTrackChapterIndices
                )
                if let idx = ReaderActiveBlockResolver.activeWord(
                    in: wordCache,
                    time: player.currentTime,
                    activeBlockID: currentBlockID
                ) {
                    activeWord = (blockID: currentBlockID ?? "", index: idx)
                } else {
                    activeWord = nil
                }
                // Phase 5: auto-expand the chapter that is currently playing.
                if let playingID = currentBlockID,
                    let playingChapter = blocks.first(where: { $0.id == playingID })?.chapterIndex
                {
                    openChapterKey = FeedAccordion.autoExpand(
                        current: openChapterKey,
                        playingChapterKey: playingChapter,
                        lastPlayingChapterKey: lastPlayingChapterKey
                    )
                    lastPlayingChapterKey = playingChapter
                }
            } else {
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

    // Equatable so the polled reader feed re-evaluates only the cards that
    // actually changed (§8.2). Rendering depends on block + isActive + the
    // highlighted word index, so a moving karaoke highlight updates only the
    // active card.
    nonisolated static func == (lhs: MacBlockCardView, rhs: MacBlockCardView) -> Bool {
        lhs.block.id == rhs.block.id && lhs.appFont == rhs.appFont && lhs.isActive == rhs.isActive
            && lhs.activeWordIndex == rhs.activeWordIndex
    }

    var body: some View {
        if let onTap {
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
            .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var blockContent: some View {
        switch block.blockKind {
        case EPubBlockRecord.Kind.heading.rawValue:
            headingCard
        case EPubBlockRecord.Kind.image.rawValue:
            imageCard
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
