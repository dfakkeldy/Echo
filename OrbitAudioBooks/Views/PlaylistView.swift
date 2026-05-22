import SwiftUI

// DEPRECATED: Playlist and Bookmarks functionality has been migrated to the
// unified Timeline feed (TimelineTab). At `.book` scope, the timeline shows
// all library audiobooks as the playlist. At `.chapter`/`.transcription`
// scopes, bookmarks appear inline as BookmarkCell items in the feed.
// This view is kept for potential watchOS reuse or future restoration.

/// A wrapper to make UUID Identifiable for use with `.sheet(item:)`.
struct IdentifiableUUID: Identifiable, Hashable {
    let id: UUID
}

/// A unified row in the playlist that mixes chapters, tracks, and bookmarks
/// in chronological order.
enum PlaylistRow: Identifiable {
    case chapter(index: Int, chapter: Chapter)
    case track(index: Int, track: Track)
    case bookmark(Bookmark)

    var id: String {
        switch self {
        case .chapter(_, let c): return "chapter-\(c.id)"
        case .track(_, let t):   return "track-\(t.id)"
        case .bookmark(let b):   return "bookmark-\(b.id.uuidString)"
        }
    }

    var sortKey: Double {
        switch self {
        case .chapter(_, let c): return c.startSeconds
        case .track(let i, _):   return Double(i) // track ordering
        case .bookmark(let b):   return b.timestamp
        }
    }
}

struct PlaylistView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var editingBookmarkID: UUID? = nil

    /// When true, renders only the list content without a NavigationStack or toolbar chrome.
    /// Used when PlaylistView is embedded inside another container view (e.g. TimelineTab fallback).
    var isEmbedded: Bool = false

    private enum PlaylistTab: Hashable { case items, bookmarks }
    @State private var selectedTab: PlaylistTab = .items
    @State private var showChapters: Bool = false

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 {
            return "\(h)h \(String(format: "%02d", m))m"
        } else {
            return "\(m)m"
        }
    }

    var body: some View {
        if isEmbedded {
            playlistContent
        } else {
            NavigationStack {
                playlistContent
                    .navigationTitle("Playlist")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Reset") { model.resetPlaylist() }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
                    .sheet(item: Binding(
                        get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
                        set: { editingBookmarkID = $0?.id }
                    )) { wrapper in
                        EditBookmarkView(bookmarkID: wrapper.id, draft: nil)
                    }
            }
            .environment(\.font, settings.appFont == SettingsManager.systemFontName ? .body : .custom(settings.appFont, size: 17, relativeTo: .body))
        }
    }

    private var playlistContent: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                Text(model.chapters.count >= 2 ? String(localized: "Chapters") : String(localized: "Tracks")).tag(PlaylistTab.items)
                Text("Bookmarks").tag(PlaylistTab.bookmarks)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if selectedTab == .items {
                List {
                    if model.isMultiM4B {
                        // Multi-M4B: hierarchical Book → Chapters
                        ForEach(model.m4bBooks) { book in
                            Section {
                                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                                    Button {
                                        model.skipToTrack(book.trackIndex)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(chapter.title ?? String(localized: "Chapter \(index + 1)"))
                                                    .foregroundStyle(.primary)
                                                Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if model.currentIndex == book.trackIndex,
                                               model.currentChapterIndex == index {
                                                Image(systemName: "play.circle.fill")
                                                    .foregroundStyle(.tint)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(book.title)
                                    if model.currentIndex == book.trackIndex {
                                        Image(systemName: "speaker.wave.2")
                                            .font(.caption)
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    } else if model.chapters.count >= 2 {
                        ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                            chapterRow(index: index, chapter: chapter)
                        }
                        .onMove { source, destination in
                            model.moveChapters(from: source, to: destination)
                        }
                    } else {
                        ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(index: index, track: track)
                        }
                        .onMove { source, destination in
                            model.moveTracks(from: source, to: destination)
                        }
                    }
                }
                .environment(\.editMode, .constant(.active))
            } else {
                let trackTitleMap: [String: String] = Dictionary(
                    uniqueKeysWithValues: model.tracks.map { ($0.id, $0.title) }
                )
                let grouped = Dictionary(grouping: model.bookmarks) { $0.trackId }
                let sortedKeys = grouped.keys.sorted { a, b in
                    let ia = a.flatMap { tid in model.tracks.firstIndex(where: { $0.id == tid }) } ?? Int.max
                    let ib = b.flatMap { tid in model.tracks.firstIndex(where: { $0.id == tid }) } ?? Int.max
                    return ia < ib
                }

                if model.bookmarks.isEmpty && !showChapters {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark button while playing to save a moment.")
                    )
                } else {
                    List {
                        if model.chapters.count >= 2 {
                            Toggle("Show Chapters", isOn: $showChapters)
                        }

                        if showChapters {
                            Section("Chapters") {
                                ForEach(model.chapters) { chapter in
                                    Button {
                                        model.seek(toSeconds: chapter.startSeconds + 0.05)
                                    } label: {
                                        HStack {
                                            Image(systemName: "list.bullet")
                                                .foregroundStyle(.secondary)
                                                .frame(width: 22)
                                            Text(chapter.title ?? String(localized: "Chapter \(chapter.index + 1)"))
                                            Spacer()
                                            Text(NowPlayingController.formatTime(chapter.startSeconds))
                                                .customFont(.caption, appFont: settings.appFont)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                    }
                                }
                            }
                        }

                        ForEach(sortedKeys, id: \.self) { trackId in
                            let bookmarks = (grouped[trackId] ?? []).sorted { $0.timestamp < $1.timestamp }
                            let header: String = trackId.flatMap { trackTitleMap[$0] } ?? "Folder Bookmarks"
                            Section(header) {
                                ForEach(bookmarks, id: \.id) { bm in
                                    bookmarkRow(bm)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chapterRow(index: Int, chapter: Chapter) -> some View {
        Button {
            model.toggleChapterEnabled(at: index)
        } label: {
            HStack {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(chapter.title ?? String(localized: "Chapter \(chapter.index + 1)"))
                Spacer()
                Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                    .customFont(.caption, appFont: settings.appFont)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
        }
    }

    @ViewBuilder
    private func trackRow(index: Int, track: Track) -> some View {
        Button {
            model.toggleTrackEnabled(at: index)
        } label: {
            HStack {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(track.title)
            }
            .foregroundStyle(track.isEnabled ? .primary : .tertiary)
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ bm: Bookmark) -> some View {
        Button {
            model.jumpToBookmark(bm)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: bm.voiceMemoFileName != nil ? "mic.fill" : "note.text")
                    .foregroundStyle(bm.isEnabled ? (bm.voiceMemoFileName != nil ? Color.red : Color.accentColor) : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bm.title.isEmpty ? String(localized: "Bookmark") : bm.title)
                        .lineLimit(1)
                    Text(NowPlayingController.formatTime(bm.timestamp))
                        .customFont(.caption, appFont: settings.appFont)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
            }
            .foregroundStyle(bm.isEnabled ? .primary : .tertiary)
        }
        .accessibilityHint(Text(bm.isEnabled
            ? String(localized: "Swipe left to edit or delete, swipe right to disable")
            : String(localized: "Swipe left to edit or delete, swipe right to enable")))
        .listRowBackground(Color.accentColor.opacity(bm.isEnabled ? 0.06 : 0.02))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleBookmarkEnabled(id: bm.id)
            } label: {
                Label(bm.isEnabled ? String(localized: "Disable") : String(localized: "Enable"), systemImage: bm.isEnabled ? "bookmark.slash" : "bookmark")
            }
            .tint(bm.isEnabled ? .orange : .green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.deleteBookmark(id: bm.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editingBookmarkID = bm.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}
