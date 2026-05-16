//
//  MacContentView.swift
//  Orbit Audiobooks macOS
//
//  Minimal Mac-native UI for opening, playing, and bookmarking audiobooks.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

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
                        Text(transcriptionManager.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ZStack {
                        PlayerPane()

                        // Live subtitle overlay — shows the current segment during playback.
                        if let subtitle = currentSubtitleSegment {
                            VStack {
                                Spacer()
                                Text(subtitle.text)
                                    .font(.title3)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)
                                    .padding(.vertical, 12)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .padding(.bottom, 16)
                            }
                        }
                    }
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
                if transcriptionManager.isTranscribing {
                    Button {
                        transcriptionManager.cancelTranscription()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        if let url = player.currentURL {
                            Task { try? await transcriptionManager.transcribe(url: url) }
                        }
                    } label: {
                        Label("Transcribe", systemImage: "text.quote")
                    }
                    .disabled(!player.hasMedia)
                }
            }
        }
        .onChange(of: player.openFileRequestToken) { _, newValue in
            if newValue != lastOpenToken {
                lastOpenToken = newValue
                showOpenPanel()
            }
        }
    }

    /// The transcription segment covering the current playback time, if available.
    private var currentSubtitleSegment: TranscriptionSegment? {
        guard player.isPlaying,
              let url = player.currentURL,
              player.currentTime > 0 else { return nil }

        let data = Data(url.path.utf8)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        guard let segments = transcriptStore.transcriptions[hash], !segments.isEmpty else { return nil }

        return segments.first { player.currentTime >= $0.startTime && player.currentTime <= $0.endTime }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Audiobook"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select an audiobook file or folder containing audio files."
        let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio]
            .compactMap { $0 }
        panel.allowedContentTypes = audioTypes
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                player.loadFolder(url: url)
            } else {
                player.open(url: url)
            }
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

            if player.hasMultipleTracks {
                Text("Track \(player.currentTrackIndex + 1) of \(player.tracks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    player.previousTrack()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMultipleTracks)

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

                Button {
                    player.nextTrack()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMultipleTracks)
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
