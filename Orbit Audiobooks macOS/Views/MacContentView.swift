//
//  MacContentView.swift
//  Orbit Audiobooks macOS
//
//  Minimal Mac-native UI for opening, playing, and bookmarking audiobooks.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var player: MacPlayerModel
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var transcriptStore = TranscriptStore()
    @State private var searchText: String = ""
    @State private var lastOpenToken: UUID = UUID()

    var body: some View {
        NavigationSplitView {
            BookmarksSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            HStack {
                VStack {
                    if transcriptionManager.isTranscribing {
                        VStack {
                            ProgressView(value: transcriptionManager.progress, total: 1.0)
                            Text(transcriptionManager.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    PlayerPane()
                }
                
                TranscriptPane(searchText: $searchText)
                    .frame(width: 300)
            }
        }
        .environmentObject(transcriptionManager)
        .environmentObject(transcriptStore)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                TextField("Search transcript...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    if let url = player.currentURL {
                        Task { try? await transcriptionManager.transcribe(url: url) }
                    }
                } label: {
                    Label("Transcribe", systemImage: "text.quote")
                }
                .disabled(!player.hasMedia || transcriptionManager.isTranscribing)
            }
        }
        .onChange(of: player.openFileRequestToken) { _, newValue in
            if newValue != lastOpenToken {
                lastOpenToken = newValue
                showOpenPanel()
            }
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Audiobook"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio]
            .compactMap { $0 }
        panel.allowedContentTypes = audioTypes
        if panel.runModal() == .OK, let url = panel.url {
            player.open(url: url)
        }
    }
}

// MARK: - Sidebar

private struct BookmarksSidebar: View {
    @EnvironmentObject private var player: MacPlayerModel
    @State private var selection: MacBookmark.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bookmarks")
                    .font(.headline)
                Spacer()
                Text("\(player.bookmarks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if player.bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark",
                    description: Text("Press ⌘B during playback to add a bookmark.")
                )
                .padding()
            } else {
                List(selection: $selection) {
                    ForEach(player.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark)
                            .tag(bookmark.id)
                            .contextMenu {
                                Button("Jump to Bookmark") {
                                    player.jumpTo(bookmark)
                                }
                                Button("Delete", role: .destructive) {
                                    player.deleteBookmark(bookmark)
                                }
                            }
                    }
                    .onDelete { offsets in
                        player.deleteBookmarks(at: offsets)
                    }
                }
                .onChange(of: selection) { _, newValue in
                    if let id = newValue,
                       let bm = player.bookmarks.first(where: { $0.id == id }) {
                        player.jumpTo(bm)
                    }
                }
            }
        }
    }
}

private struct BookmarkRow: View {
    let bookmark: MacBookmark

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bookmark.title)
                .font(.body)
                .lineLimit(1)
            Text(bookmark.fileDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(formatHMS(bookmark.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Player Pane

private struct PlayerPane: View {
    @EnvironmentObject private var player: MacPlayerModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "books.vertical")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)

            Text(player.currentTitle)
                .font(.title2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal)

            // Progress slider + times
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
                .disabled(!player.hasMedia || player.duration <= 0)

                HStack {
                    Text(formatHMS(player.currentTime))
                    Spacer()
                    Text(formatHMS(max(0, player.duration - player.currentTime)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)

            // Transport
            HStack(spacing: 24) {
                Button {
                    player.skip(by: -30)
                } label: {
                    Image(systemName: "gobackward.30")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMedia)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMedia)

                Button {
                    player.skip(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMedia)
            }

            // Speed picker
            HStack {
                Text("Speed")
                    .foregroundStyle(.secondary)
                Picker("Speed", selection: $player.playbackRate) {
                    Text("0.75×").tag(Float(0.75))
                    Text("1.0×").tag(Float(1.0))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                    Text("1.75×").tag(Float(1.75))
                    Text("2.0×").tag(Float(2.0))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

func formatHMS(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, !seconds.isNaN else { return "--:--" }
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

#Preview {
    MacContentView()
        .environmentObject(MacPlayerModel())
}
