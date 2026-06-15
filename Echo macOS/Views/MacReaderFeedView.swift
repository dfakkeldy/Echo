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
    @State private var blocks: [EPubBlockRecord] = []
    @State private var currentBlockID: String?
    @State private var isLoading = true
    /// Timeline rows (audio range → block, with chapter index) for the loaded
    /// book. Resolution scopes by chapter to the currently-playing track via the
    /// shared `ReaderActiveBlockResolver`, so per-track time collisions across
    /// multiple files no longer pin the highlight to the first track.
    @State private var timelineCache: [ReaderActiveBlockResolver.TimelineRow] = []

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
                ContentUnavailableView(
                    "No EPUB Content",
                    systemImage: "book",
                    description: Text("Import an EPUB to see the reader here.")
                )
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(blocks, id: \.id) { block in
                                MacBlockCardView(block: block, isActive: block.id == currentBlockID)
                                    .equatable()
                                    .id(block.id)
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
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Reader")
                .font(.headline)
            Spacer()
            Text("\(blocks.count) blocks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Load blocks

    private func loadBlocks() async {
        isLoading = true
        defer { isLoading = false }

        guard let audiobookID = player.audiobookID else {
            blocks = []
            timelineCache = []
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
            timelineCache = try await loadTimelineCache(audiobookID: audiobookID)
        } catch {
            blocks = []
            timelineCache = []
        }
    }

    /// Builds the audio-range → block timeline cache, LEFT JOINing `epub_block`
    /// for each block's `chapter_index`, so active-block resolution can be scoped
    /// to the currently-playing track. Ordered by `audio_start_time` to match the
    /// iOS reader's cache and the resolver's binary-search (unscoped) path.
    private func loadTimelineCache(audiobookID: String) async throws
        -> [ReaderActiveBlockResolver.TimelineRow]
    {
        let rows = try await dbService.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id, eb.chapter_index
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
            cache.append((start, end, blockID, chapterIndex))
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
            } else {
                currentBlockID = nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
        }
    }
}

// MARK: - Block Card Views

private struct MacBlockCardView: View, Equatable {
    @Environment(MacPlayerModel.self) private var player
    let block: EPubBlockRecord
    let isActive: Bool

    // Equatable so the polled reader feed re-evaluates only the cards that
    // actually changed (§8.2). Rendering depends solely on block + isActive.
    nonisolated static func == (lhs: MacBlockCardView, rhs: MacBlockCardView) -> Bool {
        lhs.block.id == rhs.block.id && lhs.isActive == rhs.isActive
    }

    var body: some View {
        Group {
            switch block.blockKind {
            case EPubBlockRecord.Kind.heading.rawValue:
                headingCard
            case EPubBlockRecord.Kind.image.rawValue:
                imageCard
            default:
                paragraphCard
            }
        }
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
    }

    // MARK: Heading Card

    private var headingCard: some View {
        Text(block.text ?? "")
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundColor(resolvedColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: Paragraph Card

    private var paragraphCard: some View {
        Text(block.text ?? "")
            .font(.body)
            .foregroundColor(resolvedColor)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("[Image]")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    // MARK: Helpers

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

// MARK: - Color from hex string

extension Color {
    fileprivate init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6,
            let value = UInt64(sanitized, radix: 16)
        else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
