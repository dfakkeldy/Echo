//
//  MacContentView.swift
//  Echo macOS
//
//  Minimal Mac-native UI for opening, playing, and bookmarking audiobooks.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @Environment(MacPlayerModel.self) private var player
    @State private var transcriptionManager = TranscriptionManager()
    @State private var transcriptStore = TranscriptStore()
    @State private var alignmentService = MacGlobalAlignmentService()
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
                    if alignmentService.isAligning {
                        VStack(spacing: 4) {
                            Text(alignmentService.alignmentStatus)
                                .font(.caption)
                            ProgressView(value: alignmentService.alignmentProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 200)

                            HStack {
                                Text("Match %:")
                                    .font(.caption)
                                Slider(value: $alignmentService.matchThreshold, in: 0.1...1.0)
                                    .frame(width: 100)
                                Text(
                                    alignmentService.matchThreshold,
                                    format: .number.precision(.fractionLength(2))
                                )
                                .font(.caption)
                            }
                            .padding(.top, 4)
                        }
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
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .padding(.bottom, 16)
                            }
                        }
                    }
                }

                TranscriptPane(searchText: $searchText)
                    .frame(width: 300)
            }
        }
        .environment(transcriptionManager)
        .environment(transcriptStore)
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

                    Button {
                        if let audioURL = player.currentURL,
                            let epubURL = showEPUBPicker()
                        {
                            // Mirror the iOS audiobook identifier
                            // (`folderURL.absoluteString`) so the shared
                            // block-ID formula matches the importer's.
                            let audiobookID = audioURL.deletingLastPathComponent().absoluteString
                            Task {
                                try? await alignmentService.alignStreaming(
                                    audiobookID: audiobookID, audioURL: audioURL, epubURL: epubURL)
                            }
                        }
                    } label: {
                        Label("Align EPUB", systemImage: "link")
                    }
                    .disabled(!player.hasMedia || alignmentService.isAligning)
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
            player.currentTime > 0
        else { return nil }

        let hash = url.sha256Hash
        guard let segments = transcriptStore.transcriptions[hash], !segments.isEmpty else {
            return nil
        }

        return segments.first {
            player.currentTime >= $0.startTime && player.currentTime <= $0.endTime
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Audiobook…")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = String(
            localized: "Select an audiobook file or folder containing audio files.")
        let audioTypes: [UTType] = [
            .audio, .mp3, .mpeg4Audio,
            UTType(filenameExtension: "aiff") ?? .audio,
            UTType(filenameExtension: "aac") ?? .audio,
            UTType(filenameExtension: "ogg") ?? .audio,
            UTType(filenameExtension: "opus") ?? .audio,
            UTType(filenameExtension: "wma") ?? .audio,
            UTType(filenameExtension: "flac") ?? .audio,
        ]
        panel.allowedContentTypes = audioTypes
        if panel.runModal() == .OK, let url = panel.url {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                player.loadFolder(url: url)
            } else {
                player.open(url: url)
            }
        }
    }

    func showEPUBPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select EPUB")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.epub, UTType.folder]
        if panel.runModal() == .OK {
            return panel.url
        }
        return nil
    }
}

// MARK: - Sidebar

private struct BookmarksSidebar: View {
    @Environment(MacPlayerModel.self) private var player
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
                        let bm = player.bookmarks.first(where: { $0.id == id })
                    {
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
    @Environment(MacPlayerModel.self) private var player

    var body: some View {
        // Environment-injected @Observable objects need @Bindable for $ bindings.
        @Bindable var player = player
        return VStack(spacing: 24) {
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
                .accessibilityLabel(Text("Playback position"))
                .accessibilityValue(Text(formatHMS(player.currentTime)))

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
                .accessibilityLabel(Text("Previous track"))

                Button {
                    player.skip(by: -30)
                } label: {
                    Image(systemName: "gobackward.30")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMedia)
                .accessibilityLabel(Text("Skip back 30 seconds"))

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMedia)
                .accessibilityLabel(Text(player.isPlaying ? "Pause" : "Play"))

                Button {
                    player.skip(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMedia)
                .accessibilityLabel(Text("Skip forward 30 seconds"))

                Button {
                    player.nextTrack()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMultipleTracks)
                .accessibilityLabel(Text("Next track"))
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

#Preview {
    MacContentView()
        .environment(MacPlayerModel())
}
