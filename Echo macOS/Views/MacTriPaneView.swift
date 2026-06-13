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
    @State private var columnVisibility = NavigationSplitViewVisibility.all

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
        .onReceive(NotificationCenter.default.publisher(for: .requestToggleDetailPane)) { _ in
            withAnimation {
                columnVisibility = columnVisibility == .detailOnly
                    ? .all
                    : (columnVisibility == .all ? .detailOnly : .all)
            }
        }
    }

    // MARK: - Player Bar

    @ViewBuilder
    private var playerBar: some View {
        if player.hasMedia {
            HStack(spacing: 12) {
                // Track info
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
                    player.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.borderless)
                .help("Skip back 15 seconds")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skip(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                }
                .buttonStyle(.borderless)
                .help("Skip forward 15 seconds")

                // Speed
                Picker("Speed", selection: Binding(
                    get: { player.playbackRate },
                    set: { player.playbackRate = $0 }
                )) {
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
