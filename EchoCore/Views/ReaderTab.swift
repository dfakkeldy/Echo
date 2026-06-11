import SwiftUI
import GRDB
import UIKit
import os.log

struct ReaderTab: View {
    let folderURL: URL
    @Environment(PlayerModel.self) var model
    @Environment(SettingsManager.self) private var settingsManager

    @State var viewModel: ReaderFeedViewModel?
    @State var showChapterPickerForBlockID: String? = nil
    @State var showCardColorPickerForBlockID: String? = nil
    @State var showChapterThemePickerForBlockID: String? = nil
    @State private var isHeaderVisible = true
    @State private var autoScrollEnabled = true
    @State private var topPartTitle: String? = nil
    @State private var topChapterTitle: String? = nil
    @State private var topSectionTitle: String? = nil
    @State private var topChapterThemeColor: String? = nil
    @State var pulseBlockID: String? = nil
    @State private var forceScrollBlockID: String? = nil
    @State private var forceScrollTrigger: Int = 0
    @AppStorage("hasSeenReaderContextMenuHint") private var hasSeenContextMenuHint = false
    @State private var showAlignmentBanner = false
    @State private var hasDismissedAlignmentBanner = false
    let haptic = UIImpactFeedbackGenerator(style: .medium)
    let logger = Logger(category: "ReaderTab")

    @State private var readerSettings = ReaderSettings(
        fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8", appFont: "System"
    )

    private var topBannerColor: Color {
        if let hex = topChapterThemeColor {
            return Color(hex: hex).opacity(0.95)
        }
        return Color(uiColor: .systemBackground).opacity(0.95)
    }

    @ViewBuilder
    private var topChapterHeaderView: some View {
        VStack(spacing: 4) {
            if let part = topPartTitle, !part.isEmpty {
                Text(part)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let title = topChapterTitle, !title.isEmpty {
                let isTop = topPartTitle?.isEmpty ?? true
                Text(title)
                    .font(isTop ? .headline : .subheadline)
                    .foregroundStyle(isTop ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, isTop ? 8 : 0)
            }
            if let section = topSectionTitle, !section.isEmpty {
                Text(section)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 4)
            }
        }
        .background(
            Rectangle()
                .fill(topChapterThemeColor.map { Color(hex: $0) } ?? .clear)
                .opacity(topChapterThemeColor != nil ? 0.3 : 0.0)
        )
        .background(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 2)
        .zIndex(1)
    }

    @ViewBuilder
    private var feedCollectionView: some View {
        if let vm = viewModel {
            let query: String? = model.epubSearchText.isEmpty ? nil : model.epubSearchText
            let bindableVM = Bindable(vm)
            
            ReaderFeedCollectionView(
                sections: vm.sections,
                activeBlockID: bindableVM.activeBlockID,
                isHeaderVisible: $isHeaderVisible,
                autoScrollEnabled: $autoScrollEnabled,
                topPartTitle: $topPartTitle,
                topChapterTitle: $topChapterTitle,
                topSectionTitle: $topSectionTitle,
                topChapterThemeColor: $topChapterThemeColor,
                settings: readerSettings,
                alignmentStatusByBlockID: vm.alignmentStatusByBlockID,
                audioStartTimeByBlockID: vm.audioStartTimeByBlockID,
                searchQuery: query,
                pulseBlockID: pulseBlockID,
                forceScrollBlockID: forceScrollBlockID,
                forceScrollTrigger: forceScrollTrigger,
                onTapBlock: { (blockID: String) -> Void in
                    seekToBlock(blockID)
                },
                onContextMenu: { (block: EPubBlockRecord) -> UIContextMenuConfiguration? in
                    buildContextMenu(block: block)
                }
            )
        }
    }

    /// The reader's own floating header: the search/utilities row (when visible),
    /// the sticky chapter-hierarchy title, and any active hint banners.
    ///
    /// Hosted via `.safeAreaInset` so the collection reserves exactly this view's
    /// measured height — replacing the old hard-coded `topInset: 110`.
    @ViewBuilder
    private var readerHeaderOverlay: some View {
        VStack(spacing: 0) {
            if isHeaderVisible {
                localUtilitiesRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            topChapterHeaderView

            // ── Context menu / alignment hints ──
            if !hasSeenContextMenuHint {
                hintBanner(
                    icon: "hand.point.up.left",
                    message: "Long-press any card to align it with the audio, change its color, bookmark it, or copy text.",
                    dismissible: true,
                    onDismiss: { withAnimation { hasSeenContextMenuHint = true } }
                )
            } else if showAlignmentBanner && !hasDismissedAlignmentBanner {
                hintBanner(
                    icon: "align.horizontal.center",
                    message: "The alignment was estimated automatically. Long-press any paragraph and choose \"Align to Now\" to make it exact — this makes the book fully searchable.",
                    dismissible: true,
                    onDismiss: { withAnimation { hasDismissedAlignmentBanner = true } }
                )
            }
        }
        .background(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 2)
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if viewModel != nil {
                // The collection fills the screen and scrolls behind the translucent
                // headers. Each `.safeAreaInset` reserves native top/bottom clearance:
                //   1. the reader's own header (self-measuring),
                //   2. Row 1 of UnifiedTopHeader (50pt, overlaid in RootTabView),
                //   3. the floating bottom dock.
                feedCollectionView
                    .safeAreaInset(edge: .top, spacing: 0) {
                        readerHeaderOverlay
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: 50)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: model.bottomInset)
                    }
            } else {
                VStack {
                    Spacer()
                    ProgressView("Loading EPUB...")
                    Spacer()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isHeaderVisible)

        .onAppear {
            let overrides = BookPreferencesService.loadOverrides(for: folderURL.absoluteString)
            readerSettings = ReaderSettings.resolved(
                fontSizeOverride: nil,
                lineSpacingOverride: nil,
                cardTintOverride: nil,
                appFontOverride: overrides.font,
                globalFontSize: settingsManager.readerFontSize,
                globalLineSpacing: settingsManager.readerLineSpacing,
                globalCardTint: settingsManager.readerCardTint,
                globalAppFont: settingsManager.appFont
            )
            loadViewModel()
        }
        .onChange(of: settingsManager.appFont) { _, newFont in
            let overrides = BookPreferencesService.loadOverrides(for: folderURL.absoluteString)
            readerSettings.appFont = BookPreferencesService.resolveAppFont(override: overrides.font, globalFont: newFont)
        }
        .onChange(of: readerSettings.fontSize) { _, newSize in settingsManager.readerFontSize = newSize }
        .onChange(of: readerSettings.lineSpacing) { _, newLineSpacing in settingsManager.readerLineSpacing = newLineSpacing }
        .onChange(of: readerSettings.cardTintHex) { _, newHex in settingsManager.readerCardTint = newHex }
        .onChange(of: model.epubSearchText) { _, newValue in
            viewModel?.searchQuery = newValue.isEmpty ? nil : newValue
        }
        .onChange(of: model.epubScrollToActiveTrigger) { _, _ in
            autoScrollEnabled = true
            if let activeID = viewModel?.activeBlockID {
                forceScrollBlockID = activeID
                forceScrollTrigger += 1
            }
        }
        .onChange(of: model.currentPlaybackTime) { _, newPos in
            viewModel?.updateActiveBlock(time: newPos)
        }
        .sheet(isPresented: $model.showReaderSettings) {
            ReaderSettingsSheet(settings: $readerSettings)
        }
        .sheet(isPresented: $model.showReaderTOC) {
            if let vm = viewModel {
                EPUBTOCSheet(
                    sections: vm.sections,
                    tocEntries: vm.tocEntries,
                    activeBlockID: vm.activeBlockID,
                    onSelect: { blockID in
                        seekToBlockAndScroll(blockID)
                        forceScrollBlockID = blockID
                        forceScrollTrigger += 1
                        model.showReaderTOC = false
                    }
                )
            }
        }
        .sheet(item: chapterPickerBinding) { ident in
            let blockID = ident.id
            ChapterPickerSheet(
                chapters: model.alignmentPickerChapters,
                onSelect: { selectedChapter in
                    alignBlock(blockID, to: selectedChapter.startSeconds, source: .chapterBoundary)
                    showChapterPickerForBlockID = nil
                }
            )
        }

        .sheet(item: cardColorPickerBinding) { ident in
            let blockID = ident.id
            CardColorPickerSheet(blockID: blockID) { blockID, colorHex in
                if let db = model.databaseService {
                    let blockDAO = EPubBlockDAO(db: db.writer)
                    do {
                        try blockDAO.setCardColor(colorHex, blockID: blockID)
                        viewModel?.reload()
                    } catch {
                        // Best-effort
                    }
                }
                showCardColorPickerForBlockID = nil
            }
        }
        .sheet(item: chapterThemePickerBinding) { ident in
            let blockID = ident.id
            CardColorPickerSheet(blockID: blockID) { blockID, colorHex in
                if let db = model.databaseService {
                    let blockDAO = EPubBlockDAO(db: db.writer)
                    do {
                        // Find the chapterIndex of the selected block
                        let allBlocks = viewModel?.sections.flatMap(\.items).compactMap { item -> EPubBlockRecord? in
                            if case .block(let b) = item { return b }
                            return nil
                        } ?? []
                        
                        if let block = allBlocks.first(where: { $0.id == blockID }),
                           let chapterIndex = block.chapterIndex {
                            try blockDAO.setChapterThemeColor(colorHex, chapterIndex: chapterIndex, audiobookID: block.audiobookID)
                            viewModel?.reload()
                            // Immediately update the top theme color so the screen background changes without scrolling
                            topChapterThemeColor = colorHex
                        }
                    } catch {
                        // Best-effort
                    }
                }
                showChapterThemePickerForBlockID = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showAutoAlignmentProgress ?? false },
            set: { viewModel?.showAutoAlignmentProgress = $0 }
        )) {
            if let vm = viewModel {
                AutoAlignmentProgressView(
                    sharedState: vm.autoAlignmentState,
                    onCancel: { vm.autoAlignmentTask?.cancel() }
                )
            }
        }
        .alert("Auto-Alignment Failed", isPresented: Binding(
            get: { viewModel?.showAutoAlignmentFailedAlert ?? false },
            set: { viewModel?.showAutoAlignmentFailedAlert = $0 }
        )) {
            Button("OK") {}
        } message: {
            Text(viewModel?.autoAlignmentErrorMessage ?? "An unknown error occurred.")
        }
        .onDisappear {
            viewModel?.autoAlignmentTask?.cancel()
        }
        .background(Color.clear)
    }

    // MARK: - Helpers

    private struct IdentifiableBlockID: Identifiable {
        let id: String
    }

    private var chapterPickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showChapterPickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showChapterPickerForBlockID = $0?.id }
        )
    }


    private var cardColorPickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showCardColorPickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showCardColorPickerForBlockID = $0?.id }
        )
    }

    private var chapterThemePickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showChapterThemePickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showChapterThemePickerForBlockID = $0?.id }
        )
    }

    private func loadViewModel() {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let vm = ReaderFeedViewModel(audiobookID: audiobookID, db: db.writer)
        vm.reload()
        self.viewModel = vm

        // Check if alignment is entirely auto-estimated (no user-created anchors yet).
        // Only show the alignment banner after the one-time context-menu hint has been dismissed.
        do {
            let lockedCount = try db.writer.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM alignment_anchor
                    WHERE audiobook_id = ? AND source != 'auto'
                    """, arguments: [audiobookID]
                ) ?? 0
            }
            if lockedCount == 0 {
                showAlignmentBanner = true
            }
        } catch {
            // Best-effort — hide banner if we can't query
            showAlignmentBanner = false
        }
    }

    private func seekToBlock(_ blockID: String) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        do {
            let startTime: Double? = try db.writer.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT audio_start_time FROM timeline_item
                    WHERE epub_block_id = ? AND audiobook_id = ?
                    LIMIT 1
                    """, arguments: [blockID, audiobookID]
                )?["audio_start_time"]
            }
            if let time = startTime, time >= 0 {
                model.playbackController.seek(to: time)
            }
        } catch {
            // Seek is best-effort
        }
    }

    private func seekToBlockAndScroll(_ blockID: String) {
        // Attempt to seek audio if the block has a timestamp
        seekToBlock(blockID)
        
        // Immediately set the active block ID so the UI scrolls to it
        // even if the block doesn't have an audio timestamp yet.
        viewModel?.activeBlockID = blockID
    }


    /// Renders a compact instructional banner.
    @ViewBuilder
    private func hintBanner(icon: String, message: String, dismissible: Bool, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if dismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss hint")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    func saveImageToCameraRoll(block: EPubBlockRecord) {
        guard let imagePath = block.imagePath else { return }
        var url = URL(fileURLWithPath: imagePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let filename = url.lastPathComponent
            let dirName = url.deletingLastPathComponent().lastPathComponent
            let appSupport = FileLocations.applicationSupportDirectory
            url = appSupport.appendingPathComponent("EPUBAssets").appendingPathComponent(dirName).appendingPathComponent(filename)
        }
        if let image = UIImage(contentsOfFile: url.path) {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }
    }

    @ViewBuilder
    private var localUtilitiesRow: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in book...", text: $model.epubSearchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !model.epubSearchText.isEmpty {
                    Button {
                        model.epubSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            
            Button {
                model.epubScrollToActiveTrigger += 1
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemBackground), in: Circle())
            .accessibilityLabel(Text("Scroll to current playback position"))
            
            Button {
                model.showReaderTOC = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16))
            }
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemBackground), in: Circle())
            .accessibilityLabel(Text("Table of Contents"))
            
            Button {
                model.showReaderSettings = true
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 16))
            }
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemBackground), in: Circle())
            .accessibilityLabel(Text("Reader settings"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// Sheet showing the EPUB's Table of Contents (sections/headings) for navigation.
struct EPUBTOCSheet: View {
    let sections: [ReaderCardSection]
    /// Publisher-declared TOC entries (NCX/nav). When present they define the
    /// tree; heading inference is only a fallback for books without one.
    var tocEntries: [EPubTOCEntryRecord] = []
    let activeBlockID: String?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var expandedChapters: Set<String> = []

    private var chapters: [TOCNode] {
        var allBlocks: [EPubBlockRecord] = []
        for section in sections {
            for item in section.items {
                if case .block(let b) = item {
                    allBlocks.append(b)
                }
            }
        }
        return TOCTreeBuilder.build(from: allBlocks, tocEntries: tocEntries)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chapters) { chapter in
                    TOCNodeView(
                        node: chapter,
                        activeBlockID: activeBlockID,
                        onSelect: { blockID in
                            onSelect(blockID)
                            dismiss()
                        },
                        expandedNodes: $expandedChapters
                    )
                }
            }
            .listStyle(.plain)
            .navigationTitle("Table of Contents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let activeID = activeBlockID {
                    func expandPath(for nodes: [TOCNode], path: [String]) -> Bool {
                        for node in nodes {
                            let newPath = path + [node.id]
                            if node.blockID == activeID || expandPath(for: node.children, path: newPath) {
                                expandedChapters.formUnion(newPath)
                                return true
                            }
                        }
                        return false
                    }
                    _ = expandPath(for: chapters, path: [])
                }
            }
        }
    }
}

struct TOCNodeView: View {
    let node: TOCNode
    let activeBlockID: String?
    let onSelect: (String) -> Void
    @Binding var expandedNodes: Set<String>

    var body: some View {
        if node.children.isEmpty {
            TOCRow(title: node.title, isActive: node.blockID == activeBlockID) {
                onSelect(node.blockID)
            }
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedNodes.contains(node.id) },
                    set: { isExp in
                        if isExp { expandedNodes.insert(node.id) }
                        else { expandedNodes.remove(node.id) }
                    }
                )
            ) {
                ForEach(node.children) { child in
                    TOCNodeView(
                        node: child,
                        activeBlockID: activeBlockID,
                        onSelect: onSelect,
                        expandedNodes: $expandedNodes
                    )
                }
            } label: {
                TOCRow(title: node.title, isActive: node.blockID == activeBlockID) {
                    onSelect(node.blockID)
                }
            }
        }
    }
}

struct TOCRow: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption.bold())
                }
            }
        }
        .buttonStyle(.plain)
    }
}
