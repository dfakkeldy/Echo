import SwiftUI
import UniformTypeIdentifiers
import os.log

/// A wrapper to make UUID Identifiable for use with `.sheet(item:)`.
struct IdentifiableUUID: Identifiable, Hashable {
    let id: UUID
}

/// A unified row in the playlist that mixes chapters, tracks, and bookmarks
/// in chronological order.
enum PlaylistRow: Identifiable {
    case partHeader(title: String, key: Int)
    case chapter(index: Int, chapter: Chapter, displayTitle: String)
    case track(index: Int, track: Track)
    case bookmark(Bookmark)

    var id: String {
        switch self {
        case .partHeader(let t, let key): return "part-\(key)-\(t)"
        case .chapter(_, let c, _): return "chapter-\(c.id)"
        case .track(_, let t):   return "track-\(t.id)"
        case .bookmark(let b):   return "bookmark-\(b.id.uuidString)"
        }
    }

    var sortKey: Double {
        switch self {
        case .partHeader: return -.infinity // emitted in order, never sorted
        case .chapter(_, let c, _): return c.startSeconds
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
    /// Used when PlaylistView is embedded inside another container view (e.g. TimelineTab).
    var isEmbedded: Bool = false
    var onRowTapped: ((TimeInterval) -> Void)? = nil
    var onZoomIn: (() -> Void)? = nil

    @State private var cachedPlaylistRows: [PlaylistRow] = []
    @State private var searchText = ""
    @State private var rebuildToken = 0
    @State private var hasEPUB = false
    @State private var hasPDF = false
    @State private var hasTranscript = false
    @State private var chapterForEPUBMatch: Chapter? = nil
    @State private var pendingEPUBMatches: [(audioChapter: Chapter, heading: EPubBlockRecord)] = []
    @State private var showPendingMatchesAlert = false

    private let logger = Logger(category: "PlaylistView")

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
                // Reserve room for Row 1 of UnifiedTopHeader (overlaid in RootTabView).
                // Native inset — stacks on the real safe area, no GeometryReader math.
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: 50)
                }
                .environment(\.editMode, .constant(model.isPlaylistEditing ? .active : .inactive))
        } else {
            NavigationStack {
                playlistContent
                    .navigationTitle("Playlist")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if model.isPlaylistEditing {
                                Button("Done") {
                                    withAnimation { model.isPlaylistEditing = false }
                                }
                            } else {
                                Button("Reset") { model.resetPlaylist() }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if model.isPlaylistEditing {
                                EmptyView()
                            } else {
                                Button("Edit") {
                                    withAnimation { model.isPlaylistEditing = true }
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
            .environment(\.editMode, .constant(model.isPlaylistEditing ? .active : .inactive))
            .environment(\.font, model.resolvedAppFont == SettingsManager.systemFontName ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
            .sheet(item: $chapterForEPUBMatch) { _ in
                if let url = model.folderURL {
                    EPUBHeadingPickerSheet(
                        folderURL: url,
                        onSelect: { heading in
                            handleEPUBMatch(heading)
                        }
                    )
                }
            }
            .alert("Match remaining chapters?", isPresented: $showPendingMatchesAlert) {
                Button("Cancel", role: .cancel) {
                    pendingEPUBMatches.removeAll()
                }
                Button("Match All") {
                    applyPendingMatches()
                }
            } message: {
                Text("Found \(pendingEPUBMatches.count) more audio chapters that can be automatically matched to EPUB headings. Would you like to match them?")
            }
        }
    }

    private func computeHierarchicalTitles(for chapters: [Chapter]) -> [String] {
        var results: [String] = []
        var stack: [(rawTitle: String, level: Int)] = []
        
        func isProperPrefix(_ prefix: String, of full: String) -> Bool {
            guard full.hasPrefix(prefix) else { return false }
            if full.count == prefix.count { return true }
            let nextChar = full[full.index(full.startIndex, offsetBy: prefix.count)]
            return nextChar.isWhitespace || nextChar.isPunctuation
        }
        
        for chapter in chapters {
            let defaultTitle = String(localized: "Chapter \(chapter.index + 1)")
            let rawTitle = (chapter.title ?? defaultTitle).applyingChapterTruncation(enabled: settings.truncateChapterNamesEnabled)
            
            while let last = stack.last, !isProperPrefix(last.rawTitle, of: rawTitle) {
                stack.removeLast()
            }
            
            if let parent = stack.last {
                let level = parent.level + 1
                let remainder = String(rawTitle.dropFirst(parent.rawTitle.count))
                let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-.,")))
                let formatted = String(repeating: ".", count: level) + (trimmed.isEmpty ? rawTitle : trimmed)
                results.append(formatted)
                stack.append((rawTitle, level))
            } else {
                results.append(rawTitle)
                stack.append((rawTitle, 0))
            }
        }
        return results
    }

    /// Increments the rebuild token to coalesce multiple source-of-truth changes
    /// (chapters, tracks, bookmarks, filters) into a single recomputation.
    private func scheduleRebuild() {
        rebuildToken &+= 1
    }

    private func recomputePlaylistRows() -> [PlaylistRow] {
        var rows: [PlaylistRow] = []
        
        if model.chapters.count >= 2 {
            // Chapter Mode: respect custom chapter ordering if reordered.
            // If showChapters is true, we iterate over the chapters in their current array order.
            if model.showChapters {
                let minStartSeconds = model.chapters.map { $0.startSeconds }.min() ?? 0.0
                
                // Show bookmarks that appear before any chapter first
                if model.showBookmarks {
                    let preBookmarks = model.bookmarks
                        .filter { $0.timestamp < minStartSeconds }
                        .sorted { $0.timestamp < $1.timestamp }
                    for bookmark in preBookmarks {
                        rows.append(.bookmark(bookmark))
                    }
                }
                
                let hierarchicalTitles = computeHierarchicalTitles(for: model.chapters)

                // Audit C2: shared part prefixes become section headers; rows
                // keep just the chapter's own title.
                let groups = ChapterPartGrouper.group(displayTitles: hierarchicalTitles)
                var chapterIndex = 0
                for (groupIndex, group) in groups.enumerated() {
                    if let header = group.header {
                        rows.append(.partHeader(title: header, key: groupIndex))
                    }
                    for rowTitle in group.rowTitles {
                        let chapter = model.chapters[chapterIndex]
                        rows.append(.chapter(index: chapterIndex, chapter: chapter, displayTitle: rowTitle))

                        if model.showBookmarks {
                            let chapterBookmarks = model.bookmarks
                                .filter { $0.timestamp >= chapter.startSeconds && $0.timestamp < chapter.endSeconds }
                                .sorted { $0.timestamp < $1.timestamp }
                            for bookmark in chapterBookmarks {
                                rows.append(.bookmark(bookmark))
                            }
                        }
                        chapterIndex += 1
                    }
                }
                return filteredBySearch(rows)
            } else if model.showBookmarks {
                // If only bookmarks are shown, display them chronologically
                return filteredBySearch(model.bookmarks
                    .sorted { $0.timestamp < $1.timestamp }
                    .map { .bookmark($0) })
            } else {
                return []
            }
        } else {
            // Track Mode: group bookmarks inline right under their parent tracks
            for (index, track) in model.tracks.enumerated() {
                if model.showChapters { // showChapters acts as "showTracks" when chapters aren't available
                    rows.append(.track(index: index, track: track))
                }
                if model.showBookmarks {
                    let trackBookmarks = model.bookmarks
                        .filter { $0.trackId == track.id }
                        .sorted(by: { $0.timestamp < $1.timestamp })
                    for bookmark in trackBookmarks {
                        rows.append(.bookmark(bookmark))
                    }
                }
            }
            return filteredBySearch(rows)
        }
    }

    /// Filters rows by the inline search field; part headers survive only if
    /// at least one of their rows does. (Inline field instead of `.searchable`
    /// because the app hides the system navigation bar.)
    private func filteredBySearch(_ rows: [PlaylistRow]) -> [PlaylistRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }

        var result: [PlaylistRow] = []
        var pendingHeader: PlaylistRow? = nil
        for row in rows {
            switch row {
            case .partHeader:
                pendingHeader = row
            case .chapter(_, _, let displayTitle):
                if displayTitle.localizedStandardContains(query) {
                    if let header = pendingHeader { result.append(header); pendingHeader = nil }
                    result.append(row)
                }
            case .track(_, let track):
                if track.title.localizedStandardContains(query) {
                    result.append(row)
                }
            case .bookmark(let bm):
                let title = bm.title.isEmpty ? String(localized: "Bookmark") : bm.title
                if title.localizedStandardContains(query) {
                    if let header = pendingHeader { result.append(header); pendingHeader = nil }
                    result.append(row)
                }
            }
        }
        return result
    }

    /// Bookmarks displayed during edit mode, sorted by timestamp.
    private var editingBookmarkRows: [Bookmark] {
        guard model.showBookmarks else { return [] }
        return model.bookmarks.sorted { $0.timestamp < $1.timestamp }
    }

    private var playlistContent: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            filterChipsRow

            if model.isPlaylistEditing {
                List {
                    editingContent

                    Color.clear
                        .frame(height: model.bottomInset)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(.clear)
            } else if cachedPlaylistRows.isEmpty {
                VStack {
                    Spacer()
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "list.bullet.rectangle",
                        description: Text("No chapters or bookmarks match the current filters.")
                    )
                    Spacer()
                }
            } else {
                List {
                    ForEach(cachedPlaylistRows) { row in
                        switch row {
                        case .partHeader(let title, _):
                            Text(title)
                                .customFont(.caption, weight: .semibold, appFont: model.resolvedAppFont)
                                .textCase(.uppercase)
                                .kerning(0.8)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                                .padding(.top, 12)
                                .accessibilityAddTraits(.isHeader)
                        case .chapter(let index, let chapter, let displayTitle):
                            chapterRow(index: index, chapter: chapter, displayTitle: displayTitle)
                        case .track(let index, let track):
                            trackRow(index: index, track: track)
                        case .bookmark(let bm):
                            bookmarkRow(bm)
                        }
                    }

                    // Empty space at bottom to ensure items scroll past the floating BottomToolbarView
                    Color.clear
                        .frame(height: model.bottomInset)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(.clear)
            }
        }
        .fileImporter(
            isPresented: $model.showingDocumentImporter,
            allowedContentTypes: [UTType(filenameExtension: "epub"), UTType.pdf].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                if selectedURL.pathExtension.lowercased() == "pdf" {
                    model.importPDF(from: selectedURL)
                } else {
                    model.importEPUB(from: selectedURL)
                }
            case .failure(let error):
                logger.error("Failed to select document: \(error)")
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
            hasPDF = model.hasPDF
            hasTranscript = model.hasTranscript
            cachedPlaylistRows = recomputePlaylistRows()
        }
        .onChange(of: model.folderURL) { _, _ in
            hasEPUB = model.hasEPUB
            hasPDF = model.hasPDF
            hasTranscript = model.hasTranscript
        }
        .onChange(of: model.chapters) { _, _ in scheduleRebuild() }
        .onChange(of: model.tracks) { _, _ in scheduleRebuild() }
        .onChange(of: model.bookmarks) { _, _ in scheduleRebuild() }
        .onChange(of: model.showChapters) { _, _ in scheduleRebuild() }
        .onChange(of: model.showBookmarks) { _, _ in scheduleRebuild() }
        .onChange(of: searchText) { _, _ in scheduleRebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) { notification in
            guard let ingestedID = notification.userInfo?["audiobookID"] as? String,
                  let audiobookID = model.folderURL?.absoluteString,
                  ingestedID == audiobookID
            else { return }
            hasEPUB = model.hasEPUB
            hasPDF = model.hasPDF
            hasTranscript = model.hasTranscript
        }
        .task(id: rebuildToken) {
            guard rebuildToken > 0 else { return }
            // Tiny yield so multiple synchronous source-of-truth mutations
            // coalesce into a single `recomputePlaylistRows()` call.
            try? await Task.sleep(for: .milliseconds(16))
            cachedPlaylistRows = recomputePlaylistRows()
        }
    }

    /// Audit C3: a self-describing segmented control instead of ambiguous
    /// glyph chips. "All" preserves the interleaved chapters+bookmarks view.
    private enum PlaylistFilter: Hashable { case all, chapters, bookmarks }

    private var filterSelection: Binding<PlaylistFilter> {
        Binding(
            get: {
                switch (model.showChapters, model.showBookmarks) {
                case (true, false): return .chapters
                case (false, true): return .bookmarks
                default: return .all
                }
            },
            set: { newValue in
                switch newValue {
                case .all: model.showChapters = true; model.showBookmarks = true
                case .chapters: model.showChapters = true; model.showBookmarks = false
                case .bookmarks: model.showChapters = false; model.showBookmarks = true
                }
            }
        )
    }

    @ViewBuilder
    private var filterChipsRow: some View {
        @Bindable var model = model
        VStack(spacing: 8) {
        HStack(spacing: 12) {
            Picker("Show", selection: filterSelection) {
                Text("All").tag(PlaylistFilter.all)
                Text(model.chapters.count >= 2 ? "Chapters" : "Tracks").tag(PlaylistFilter.chapters)
                Text("Bookmarks").tag(PlaylistFilter.bookmarks)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            if isEmbedded && (model.chapters.count >= 2 || model.tracks.count > 1) {
                Button {
                    withAnimation { model.isPlaylistEditing.toggle() }
                } label: {
                    Image(systemName: model.isPlaylistEditing ? "checkmark.circle.fill" : "arrow.up.and.down")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(model.isPlaylistEditing ? String(localized: "Done") : String(localized: "Reorder"))
            }

            Spacer()
            
            if hasEPUB || hasPDF || hasTranscript {
                Button {
                    if let action = onZoomIn {
                        action()
                    } else {
                        model.selectedTab = .read
                    }
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .accessibilityLabel(String(localized: "Read companion document"))
                .contextMenu {
                    Button {
                        model.showingDocumentImporter = true
                    } label: {
                        Label(String(localized: "Replace Document"), systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    }
                }
            } else {
                Button {
                    model.showingDocumentImporter = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(String(localized: "Import Document"))
            }
        }
        .padding(.horizontal, 16)

        // Inline search field (stands in for `.searchable`, which needs the
        // hidden system navigation bar to render).
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search chapters & bookmarks", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }


    @ViewBuilder
    private func chapterRow(index: Int, chapter: Chapter, displayTitle: String) -> some View {
        let sections = model.state.chapterSections[index] ?? []
        if sections.isEmpty {
            chapterRowContent(index: index, chapter: chapter, displayTitle: displayTitle)
        } else {
            DisclosureGroup {
                ForEach(sections) { section in
                    sectionRow(section)
                }
            } label: {
                chapterRowContent(index: index, chapter: chapter, displayTitle: displayTitle)
            }
            .tint(.secondary)
        }
    }

    @ViewBuilder
    private func chapterRowContent(index: Int, chapter: Chapter, displayTitle: String) -> some View {
        HStack {
            // Audit C1 (inverted on purpose): the whole row toggles the chapter
            // — an accidental toggle is harmless and instantly visible; an
            // accidental play loses your place. Playback lives in the trailing
            // 44pt button.
            Button {
                model.toggleChapterEnabled(at: index)
                Haptic.play(.rigid)
            } label: {
                HStack {
                    Image(systemName: chapter.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chapter.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .foregroundStyle(.primary)
                        Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                            .customFont(.caption, appFont: model.resolvedAppFont)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.currentChapterIndex == index {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                            .accessibilityLabel(Text("Now playing"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(displayTitle))
            .accessibilityValue(Text(chapter.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled")))
            .accessibilityHint(Text("Double tap to toggle this chapter"))

            Button {
                model.seek(toSeconds: chapter.startSeconds + 0.05)
                onRowTapped?(chapter.startSeconds)
                Haptic.play(.light)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Play \(displayTitle)"))
        }
        .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
        .opacity(chapter.isEnabled ? 1.0 : 0.35)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleChapterEnabled(at: index)
            } label: {
                Label(chapter.isEnabled ? String(localized: "Disable") : String(localized: "Enable"), systemImage: chapter.isEnabled ? "eye.slash" : "eye")
            }
            .tint(chapter.isEnabled ? .orange : .green)
        }
        .contextMenu {
            if hasEPUB {
                Button {
                    chapterForEPUBMatch = chapter
                } label: {
                    Label("Match EPUB Chapter", systemImage: "link")
                }
            }
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: Chapter) -> some View {
        Button {
            model.seek(toSeconds: section.startSeconds + 0.05)
            onRowTapped?(section.startSeconds)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title ?? String(localized: "Section"))
                        .foregroundStyle(.primary)
                        .font(.subheadline)
                    Text(formatDuration(section.endSeconds - section.startSeconds))
                        .customFont(.caption, appFont: model.resolvedAppFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Highlight if playing in this section
                let currentTime = model.currentPlaybackTime
                if currentTime >= section.startSeconds && currentTime < section.endSeconds {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.subheadline)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func trackRow(index: Int, track: Track) -> some View {
        HStack {
            // Same inversion as chapter rows (audit C1): row toggles, trailing
            // button plays.
            Button {
                model.toggleTrackEnabled(at: index)
                Haptic.play(.rigid)
            } label: {
                HStack {
                    Image(systemName: track.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(track.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 22)
                    Text(track.title)
                    Spacer()
                    if model.currentIndex == index {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                            .accessibilityLabel(Text("Now playing"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(track.title))
            .accessibilityValue(Text(track.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled")))
            .accessibilityHint(Text("Double tap to toggle this track"))

            Button {
                model.skipToTrack(index)
                onRowTapped?(0)
                Haptic.play(.light)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Play \(track.title)"))
        }
        .foregroundStyle(track.isEnabled ? .primary : .tertiary)
        .opacity(track.isEnabled ? 1.0 : 0.35)
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
            if model.showChapters {
                Section("Chapters") {
                    let hierarchicalTitles = computeHierarchicalTitles(for: model.chapters)
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                        editingChapterRow(index: index, chapter: chapter, displayTitle: hierarchicalTitles[index])
                    }
                    .onMove { source, destination in
                        model.moveChapters(from: source, to: destination)
                    }
                }
            }
        } else if model.showChapters {
            Section("Tracks") {
                ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                    editingTrackRow(index: index, track: track)
                }
                .onMove { source, destination in
                    model.moveTracks(from: source, to: destination)
                }
            }
        }

        if model.showBookmarks {
            ForEach(editingBookmarkRows, id: \.id) { bm in
                bookmarkRow(bm)
            }
        }
    }

    @ViewBuilder
    private func editingChapterRow(index: Int, chapter: Chapter, displayTitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
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
        .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
        .opacity(chapter.isEnabled ? 1.0 : 0.35)
    }

    @ViewBuilder
    private func editingTrackRow(index: Int, track: Track) -> some View {
        HStack {
            Text(track.title)
            Spacer()
            if model.currentIndex == index {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.tint)
                }
            }
        .foregroundStyle(track.isEnabled ? .primary : .tertiary)
        .opacity(track.isEnabled ? 1.0 : 0.35)
    }

    private func handleEPUBMatch(_ heading: EPubBlockRecord) {
        guard let audioChapter = chapterForEPUBMatch,
              let db = model.databaseService,
              let audiobookID = model.folderURL?.absoluteString else { return }

        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.moveBlockToCurrentTime(blockID: heading.id, time: audioChapter.startSeconds)
            let haptic = UINotificationFeedbackGenerator()
            haptic.notificationOccurred(.success)
        } catch {
            logger.error("Failed to align chapter: \(error.localizedDescription)")
        }

        let dao = EPubBlockDAO(db: db.writer)
        do {
            let allBlocks = try dao.blocks(for: audiobookID)
            let allHeadings = allBlocks.filter { $0.blockKind == EPubBlockRecord.Kind.heading.rawValue && !($0.text?.isEmpty ?? true) }
            
            let audioChapters = model.alignmentPickerChapters
            guard let audioIdx = audioChapters.firstIndex(where: { $0.id == audioChapter.id }),
                  let headingIdx = allHeadings.firstIndex(where: { $0.id == heading.id }) else { return }
            
            let remainingAudio = audioChapters.dropFirst(audioIdx + 1)
            let remainingHeadings = allHeadings.dropFirst(headingIdx + 1)
            
            let matchCount = min(remainingAudio.count, remainingHeadings.count)
            if matchCount > 0 {
                var pending: [(audioChapter: Chapter, heading: EPubBlockRecord)] = []
                for i in 0..<matchCount {
                    let a = remainingAudio[remainingAudio.startIndex + i]
                    let h = remainingHeadings[remainingHeadings.startIndex + i]
                    pending.append((a, h))
                }
                pendingEPUBMatches = pending
                showPendingMatchesAlert = true
            }
        } catch {
            logger.error("Failed to check remaining chapters: \(error.localizedDescription)")
        }
    }

    private func applyPendingMatches() {
        guard let db = model.databaseService,
              let audiobookID = model.folderURL?.absoluteString else { return }
        
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        for match in pendingEPUBMatches {
            do {
                try alignmentService.moveBlockToCurrentTime(blockID: match.heading.id, time: match.audioChapter.startSeconds)
            } catch {
                logger.error("Failed to align pending chapter: \(error.localizedDescription)")
            }
        }
        
        let haptic = UINotificationFeedbackGenerator()
        haptic.notificationOccurred(.success)
        pendingEPUBMatches.removeAll()
    }
}
