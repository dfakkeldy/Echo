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
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var dbServiceWired = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacTOCTreeView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } content: {
            VStack(spacing: 0) {
                MacReaderFeedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                playerBar
                    .frame(height: 48)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 450)
        } detail: {
            MacNotesPane()
                .navigationSplitViewColumnWidth(min: 200, ideal: 300, max: 500)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            if !dbServiceWired {
                player.dbService = dbService
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
                            .font(.caption)
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
                            .font(.caption)
                            .lineLimit(1)
                        if player.hasMultipleTracks {
                            Text("Track \(player.currentTrackIndex + 1) of \(player.tracks.count)")
                                .font(.caption2)
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

                // Sleep timer
                Menu {
                    Button("Off") { player.sleepTimerMode = .off }
                    Divider()
                    Button("5 min") { player.sleepTimerMode = .minutes(5) }
                    Button("10 min") { player.sleepTimerMode = .minutes(10) }
                    Button("15 min") { player.sleepTimerMode = .minutes(15) }
                    Button("30 min") { player.sleepTimerMode = .minutes(30) }
                    Button("45 min") { player.sleepTimerMode = .minutes(45) }
                    Button("60 min") { player.sleepTimerMode = .minutes(60) }
                    Divider()
                    Button("End of Chapter") { player.sleepTimerMode = .endOfChapter }
                } label: {
                    Image(
                        systemName: player.sleepTimer.mode == .off
                            ? "moon.zzz" : "moon.zzz.fill"
                    )
                }
                .buttonStyle(.borderless)
                .help("Sleep timer")
                .frame(width: 28)

                // Speed
                Picker(
                    "Speed",
                    selection: Binding(
                        get: { player.playbackRate },
                        set: { player.playbackRate = $0 }
                    )
                ) {
                    Text("1×").tag(Float(1.0))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                    Text("2×").tag(Float(2.0))
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 60)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Text("No audiobook loaded — press ⌘O to open one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
