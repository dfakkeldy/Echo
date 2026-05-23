import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isEditing: Bool = false

    /// When true, renders only the list content without a NavigationStack or toolbar chrome.
    /// Used when PlaylistView is embedded inside another container view (e.g. TimelineTab).
    var isEmbedded: Bool = false
    var onRowTapped: ((TimeInterval) -> Void)? = nil
    var onZoomIn: (() -> Void)? = nil

    @State private var showChapters: Bool = true
    @State private var showBookmarks: Bool = true
    @State private var showingEPUBImporter: Bool = false
    @State private var hasEPUB = false
    @State private var hasTranscript = false

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
                .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        } else {
            NavigationStack {
                playlistContent
                    .navigationTitle("Playlist")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if isEditing {
                                Button("Done") {
                                    withAnimation { isEditing = false }
                                }
                            } else {
                                Button("Reset") { model.resetPlaylist() }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if isEditing {
                                EmptyView()
                            } else {
                                Button("Edit") {
                                    withAnimation { isEditing = true }
                                }
                                Button("Done") { dismiss() }
                            }
                        }
                    }
                    .sheet(item: Binding(
                        get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
                        set: { editingBookmarkID = $0?.id }
                    )) { wrapper in
                        EditBookmarkView(bookmarkID: wrapper.id, draft: nil)
                    }
            }
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .environment(\.font, model.resolvedAppFont == SettingsManager.systemFontName ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
        }
    }

    private var playlistRows: [PlaylistRow] {
        var rows: [PlaylistRow] = []
        
        if model.chapters.count >= 2 {
            // Chapter Mode: combine chapters & bookmarks globally by timeline position
            if showChapters {
                for (index, chapter) in model.chapters.enumerated() {
                    rows.append(.chapter(index: index, chapter: chapter))
                }
            }
            if showBookmarks {
                for bookmark in model.bookmarks {
                    rows.append(.bookmark(bookmark))
                }
            }
            return rows.sorted { a, b in
                let timeA = a.sortKey
                let timeB = b.sortKey
                if timeA == timeB {
                    switch (a, b) {
                    case (.chapter, .bookmark): return true
                    case (.bookmark, .chapter): return false
                    default: return false
                    }
                }
                return timeA < timeB
            }
        } else {
            // Track Mode: group bookmarks inline right under their parent tracks
            for (index, track) in model.tracks.enumerated() {
                if showChapters { // showChapters acts as "showTracks" when chapters aren't available
                    rows.append(.track(index: index, track: track))
                }
                if showBookmarks {
                    let trackBookmarks = model.bookmarks
                        .filter { $0.trackId == track.id }
                        .sorted(by: { $0.timestamp < $1.timestamp })
                    for bookmark in trackBookmarks {
                        rows.append(.bookmark(bookmark))
                    }
                }
            }
            return rows
        }
    }

    /// Bookmarks displayed during edit mode, sorted by timestamp.
    private var editingBookmarkRows: [Bookmark] {
        guard showBookmarks else { return [] }
        return model.bookmarks.sorted { $0.timestamp < $1.timestamp }
    }

    private var playlistContent: some View {
        VStack(spacing: 0) {
            // Horizontal Filter Chips Row
            HStack(spacing: 12) {
                Toggle(isOn: $showChapters) {
                    Text(model.chapters.count >= 2 ? "Chapters" : "Tracks")
                }
                .toggleStyle(.button)
                
                Toggle(isOn: $showBookmarks) {
                    Text("Bookmarks")
                }
                .toggleStyle(.button)

                if isEmbedded && (model.chapters.count >= 2 || model.tracks.count > 1) {
                    Button(isEditing ? "Done" : "Reorder") {
                        withAnimation { isEditing.toggle() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .customFont(.caption, weight: .semibold, appFont: model.resolvedAppFont)
                }

                Spacer()
                
                if hasEPUB || hasTranscript {
                    if onZoomIn != nil {
                        Button {
                            onZoomIn?()
                        } label: {
                            Label("Read", systemImage: "doc.text.magnifyingglass")
                                .customFont(.subheadline, weight: .semibold, appFont: model.resolvedAppFont)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                    }
                } else {
                    Button {
                        showingEPUBImporter = true
                    } label: {
                        Label("Import EPUB", systemImage: "doc.badge.plus")
                            .customFont(.subheadline, weight: .semibold, appFont: model.resolvedAppFont)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if isEditing {
                List {
                    editingContent

                    Color.clear
                        .frame(height: 95)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            } else if playlistRows.isEmpty {
                ContentUnavailableView(
                    "No Items",
                    systemImage: "list.bullet.rectangle",
                    description: Text("No chapters or bookmarks match the current filters.")
                )
            } else {
                List {
                    ForEach(playlistRows) { row in
                        switch row {
                        case .chapter(let index, let chapter):
                            chapterRow(index: index, chapter: chapter)
                        case .track(let index, let track):
                            trackRow(index: index, track: track)
                        case .bookmark(let bm):
                            bookmarkRow(bm)
                        }
                    }

                    // Empty space at bottom to ensure items scroll past the floating BottomToolbarView
                    Color.clear
                        .frame(height: 95)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .fileImporter(
            isPresented: $showingEPUBImporter,
            allowedContentTypes: [UTType(filenameExtension: "epub")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                model.importEPUB(from: selectedURL)
            case .failure(let error):
                print("Failed to select EPUB: \(error)")
            }
        }
        .sheet(item: Binding(
            get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
            set: { editingBookmarkID = $0?.id }
        )) { wrapper in
            EditBookmarkView(bookmarkID: wrapper.id, draft: nil)
        }
        .onAppear {
            hasEPUB = model.hasEPUB
            hasTranscript = model.hasTranscript
        }
        .onChange(of: model.folderURL) { _, _ in
            hasEPUB = model.hasEPUB
            hasTranscript = model.hasTranscript
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) { notification in
            guard let ingestedID = notification.userInfo?["audiobookID"] as? String,
                  let audiobookID = model.folderURL?.absoluteString,
                  ingestedID == audiobookID
            else { return }
            hasEPUB = model.hasEPUB
            hasTranscript = model.hasTranscript
        }
    }

    @ViewBuilder
    private func chapterRow(index: Int, chapter: Chapter) -> some View {
        HStack(spacing: 0) {
            Button {
                model.seek(toSeconds: chapter.startSeconds + 0.05)
                onRowTapped?(chapter.startSeconds)
            } label: {
                HStack {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title ?? String(localized: "Chapter \(chapter.index + 1)"))
                            .foregroundStyle(.primary)
                        Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                            .customFont(.caption, appFont: model.resolvedAppFont)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.currentChapterIndex == index {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                model.toggleChapterEnabled(at: index)
            } label: {
                Image(systemName: chapter.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chapter.isEnabled ? String(localized: "Disable chapter") : String(localized: "Enable chapter"))
        }
        .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleChapterEnabled(at: index)
            } label: {
                Label(chapter.isEnabled ? String(localized: "Disable") : String(localized: "Enable"), systemImage: chapter.isEnabled ? "eye.slash" : "eye")
            }
            .tint(chapter.isEnabled ? .orange : .green)
        }
    }

    @ViewBuilder
    private func trackRow(index: Int, track: Track) -> some View {
        HStack(spacing: 0) {
            Button {
                model.skipToTrack(index)
                onRowTapped?(0)
            } label: {
                HStack {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text(track.title)
                    Spacer()
                    if model.currentIndex == index {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                model.toggleTrackEnabled(at: index)
            } label: {
                Image(systemName: track.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.isEnabled ? String(localized: "Disable track") : String(localized: "Enable track"))
        }
        .foregroundStyle(track.isEnabled ? .primary : .tertiary)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleTrackEnabled(at: index)
            } label: {
                Label(track.isEnabled ? String(localized: "Disable") : String(localized: "Enable"), systemImage: track.isEnabled ? "eye.slash" : "eye")
            }
            .tint(track.isEnabled ? .orange : .green)
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ bm: Bookmark) -> some View {
        Button {
            model.jumpToBookmark(bm)
            onRowTapped?(bm.timestamp)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: bm.voiceMemoFileName != nil ? "mic.fill" : "note.text")
                    .foregroundStyle(bm.isEnabled ? (bm.voiceMemoFileName != nil ? Color.red : Color.accentColor) : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bm.title.isEmpty ? String(localized: "Bookmark") : bm.title)
                        .lineLimit(1)
                    Text(NowPlayingController.formatTime(bm.timestamp))
                        .customFont(.caption, appFont: model.resolvedAppFont)
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

    // MARK: - Edit Mode Content

    @ViewBuilder
    private var editingContent: some View {
        if model.chapters.count >= 2 {
            if showChapters {
                Section("Chapters") {
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                        editingChapterRow(index: index, chapter: chapter)
                    }
                    .onMove { source, destination in
                        model.moveChapters(from: source, to: destination)
                    }
                }
            }
        } else if showChapters {
            Section("Tracks") {
                ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                    editingTrackRow(index: index, track: track)
                }
                .onMove { source, destination in
                    model.moveTracks(from: source, to: destination)
                }
            }
        }

        if showBookmarks {
            ForEach(editingBookmarkRows, id: \.id) { bm in
                bookmarkRow(bm)
            }
        }
    }

    @ViewBuilder
    private func editingChapterRow(index: Int, chapter: Chapter) -> some View {
        HStack {
            Image(systemName: "list.bullet")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title ?? String(localized: "Chapter \(chapter.index + 1)"))
                Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                    .customFont(.caption, appFont: model.resolvedAppFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.currentChapterIndex == index {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.tint)
            }
            Button {
                model.toggleChapterEnabled(at: index)
            } label: {
                Image(systemName: chapter.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chapter.isEnabled ? String(localized: "Disable chapter") : String(localized: "Enable chapter"))
        }
        .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
    }

    @ViewBuilder
    private func editingTrackRow(index: Int, track: Track) -> some View {
        HStack {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(track.title)
            Spacer()
            if model.currentIndex == index {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.tint)
            }
            Button {
                model.toggleTrackEnabled(at: index)
            } label: {
                Image(systemName: track.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.isEnabled ? String(localized: "Disable track") : String(localized: "Enable track"))
        }
        .foregroundStyle(track.isEnabled ? .primary : .tertiary)
    }
}
