import SwiftUI
import GRDB

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
        } catch {
            blocks = []
        }
    }

    /// Periodically queries the database for the block at the current playback
    /// time, so the reader can highlight and auto-scroll to the active block.
    private func trackCurrentBlock() async {
        while !Task.isCancelled {
            if let audiobookID = player.audiobookID,
               player.isPlaying,
               player.currentTime > 0 {
                do {
                    let blockID = try await dbService.writer.read { db in
                        try Row.fetchOne(db, sql: """
                            SELECT eb.id
                            FROM epub_block eb
                            JOIN timeline_item ti ON ti.epub_block_id = eb.id
                            WHERE eb.audiobook_id = ?
                              AND ti.audio_start_time <= ?
                              AND ti.audio_end_time > ?
                            ORDER BY eb.sequence_index
                            LIMIT 1
                            """, arguments: [audiobookID, player.currentTime, player.currentTime]
                        )?["id"] as? String
                    }
                    currentBlockID = blockID
                } catch {
                    // Silently ignore query failures
                }
            } else {
                currentBlockID = nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
    }
}

// MARK: - Block Card Views

private struct MacBlockCardView: View {
    @Environment(MacPlayerModel.self) private var player
    let block: EPubBlockRecord
    let isActive: Bool

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
                   let nsImage = NSImage(contentsOf: resolvedURL) {
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
        let base = folderURL
            .deletingLastPathComponent()
            .appendingPathComponent(assetsDir)
            .appendingPathComponent("EPUBAssets")
        let url = base.appendingPathComponent(imagePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Color from hex string

private extension Color {
    init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6,
              let value = UInt64(sanitized, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
