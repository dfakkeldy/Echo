import SwiftUI
import GRDB
import UIKit
import os.log

struct ReaderTab: View {
    let folderURL: URL
    @Environment(PlayerModel.self) var model
    @Environment(SettingsManager.self) private var settingsManager

    @State var viewModel: ReaderFeedViewModel?
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showTOC = false
    @State var showChapterPickerForBlockID: String? = nil
    @State var showEndChapterPickerForBlockID: String? = nil
    @State var showCardColorPickerForBlockID: String? = nil
    @State private var isHeaderVisible = true
    @State private var autoScrollEnabled = true
    @State private var topChapterTitle: String? = nil
    @State private var topSectionTitle: String? = nil
    @State var pulseBlockID: String? = nil
    @State private var forceScrollBlockID: String? = nil
    @State private var forceScrollTrigger: Int = 0
    @AppStorage("hasSeenReaderContextMenuHint") private var hasSeenContextMenuHint = false
    @State private var showAlignmentBanner = false
    @State private var hasDismissedAlignmentBanner = false
    @State var autoAlignmentTask: Task<Void, Error>?
    @State var showAutoAlignmentProgress = false
    @State var showAutoAlignmentFailedAlert = false
    @State var autoAlignmentErrorMessage: String?
    @State var autoAlignmentState = AutoAlignmentState()
    let haptic = UIImpactFeedbackGenerator(style: .medium)
    let logger = Logger(category: "ReaderTab")

    @State private var readerSettings = ReaderSettings(
        fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8"
    )

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let vm = viewModel {
                    if isHeaderVisible {
                        ReaderHeaderView(
                            searchText: $searchText,
                            chapterTitle: "EPUB Reader",
                            onScrollToActiveTap: {
                                autoScrollEnabled = true
                                if let activeID = viewModel?.activeBlockID {
                                    forceScrollBlockID = activeID
                                    forceScrollTrigger += 1
                                }
                            },
                            onTOCTap: { showTOC = true },
                            onSettingsTap: { showSettings = true }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    VStack(spacing: 4) {
                        if let title = topChapterTitle, !title.isEmpty {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }
                        if let section = topSectionTitle, !section.isEmpty {
                            Text(section)
                                .font(.subheadline)
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
                            .fill(Color(uiColor: .systemBackground).opacity(0.95))
                            .shadow(color: Color.black.opacity(0.05), radius: 3, y: 2)
                    )
                    .zIndex(1)

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

                    ReaderFeedCollectionView(
                        sections: vm.sections,
                        activeBlockID: Bindable(vm).activeBlockID,
                        isHeaderVisible: $isHeaderVisible,
                        autoScrollEnabled: $autoScrollEnabled,
                        topChapterTitle: $topChapterTitle,
                        topSectionTitle: $topSectionTitle,
                        settings: readerSettings,
                        alignmentStatusByBlockID: vm.alignmentStatusByBlockID,
                        audioStartTimeByBlockID: vm.audioStartTimeByBlockID,
                        searchQuery: searchText.isEmpty ? nil : searchText,
                        pulseBlockID: pulseBlockID,
                        forceScrollBlockID: forceScrollBlockID,
                        forceScrollTrigger: forceScrollTrigger,
                        onTapBlock: { blockID in
                            seekToBlock(blockID)
                        },
                        onContextMenu: { block in
                            buildContextMenu(block: block)
                        }
                    )
                } else {
                    Spacer()
                    ProgressView("Loading EPUB...")
                    Spacer()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isHeaderVisible)

            VStack {
                Spacer()
            }
        }
        .onAppear {
            loadViewModel()
        }
        .onChange(of: searchText) { _, newValue in
            viewModel?.searchQuery = newValue.isEmpty ? nil : newValue
        }
        .onChange(of: model.currentPlaybackTime) { _, newPos in
            viewModel?.updateActiveBlock(time: newPos)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(settings: $readerSettings)
        }
        .sheet(isPresented: $showTOC) {
            if let vm = viewModel {
                EPUBTOCSheet(
                    sections: vm.sections,
                    activeBlockID: vm.activeBlockID,
                    onSelect: { blockID in
                        seekToBlockAndScroll(blockID)
                        forceScrollBlockID = blockID
                        forceScrollTrigger += 1
                        showTOC = false
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
        .sheet(item: endChapterPickerBinding) { ident in
            let blockID = ident.id
            ChapterPickerSheet(
                chapters: model.alignmentPickerChapters,
                onSelect: { selectedChapter in
                    alignChapterEnd(blockID, chapterIndex: nil, to: selectedChapter.endSeconds)
                    showEndChapterPickerForBlockID = nil
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
        .sheet(isPresented: $showAutoAlignmentProgress) {
            AutoAlignmentProgressView(
                sharedState: autoAlignmentState,
                onCancel: { autoAlignmentTask?.cancel() }
            )
        }
        .alert("Auto-Alignment Failed", isPresented: $showAutoAlignmentFailedAlert) {
            Button("OK") {}
        } message: {
            Text(autoAlignmentErrorMessage ?? "An unknown error occurred.")
        }
        .background(Color(uiColor: .systemBackground))
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

    private var endChapterPickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showEndChapterPickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showEndChapterPickerForBlockID = $0?.id }
        )
    }

    private var cardColorPickerBinding: Binding<IdentifiableBlockID?> {
        Binding<IdentifiableBlockID?>(
            get: { showCardColorPickerForBlockID.map(IdentifiableBlockID.init) },
            set: { showCardColorPickerForBlockID = $0?.id }
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
}

struct TOCNode: Identifiable {
    let id: String
    var title: String
    let blockID: String
    var children: [TOCNode]
}


/// Sheet showing the EPUB's Table of Contents (sections/headings) for navigation.
struct EPUBTOCSheet: View {
    let sections: [ReaderCardSection]
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
        
        var rootNodes: [TOCNode] = []
        var currentPartNodes: [TOCNode] = []
        var currentPartId: String? = nil
        var currentPartTitle: String = ""
        var currentPartBlockID: String = ""
        
        var currentChapterNodes: [TOCNode] = []
        var currentChapterId: String? = nil
        var currentChapterTitle: String = ""
        var currentChapterBlockID: String = ""

        func flushChapter() {
            if let cid = currentChapterId {
                let c = TOCNode(id: cid, title: currentChapterTitle, blockID: currentChapterBlockID, children: currentChapterNodes)
                if currentPartId != nil {
                    currentPartNodes.append(c)
                } else {
                    rootNodes.append(c)
                }
            }
            currentChapterNodes = []
            currentChapterId = nil
        }

        func flushPart() {
            flushChapter()
            if let pid = currentPartId {
                let p = TOCNode(id: pid, title: currentPartTitle, blockID: currentPartBlockID, children: currentPartNodes)
                rootNodes.append(p)
            }
            currentPartNodes = []
            currentPartId = nil
        }
        
        var currentSpineIndex = -1
        var fallbackBlock: EPubBlockRecord? = nil

        func flushFallback() {
            if let block = fallbackBlock {
                flushChapter()
                let fallbackTitle = URL(fileURLWithPath: block.spineHref).deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                currentChapterId = "spine-\(block.spineIndex)"
                currentChapterTitle = fallbackTitle
                currentChapterBlockID = block.id
            }
            fallbackBlock = nil
        }

        for block in allBlocks {
            if block.spineIndex != currentSpineIndex {
                flushFallback()
                flushChapter()
                currentSpineIndex = block.spineIndex
                fallbackBlock = block
            }
            
            if block.blockKind == EPubBlockRecord.Kind.heading.rawValue, let text = block.text, !text.isEmpty {
                let lower = text.lowercased()
                if lower == "tip" || lower == "warning" || lower == "note" || lower == "caution" || lower == "important" {
                    continue
                }
                if text.count > 100 { continue }
                if lower.contains("front matter") || lower == "title" || lower == "copyright" {
                    continue
                }
                
                if fallbackBlock != nil {
                    // First heading in this spine
                    fallbackBlock = nil
                    
                    if lower.hasPrefix("part ") {
                        flushPart()
                        currentPartId = block.id
                        currentPartTitle = text
                        currentPartBlockID = block.id
                    } else {
                        currentChapterId = block.id
                        currentChapterTitle = text
                        currentChapterBlockID = block.id
                    }
                } else {
                    // Subsequent heading in same spine
                    let sectionNode = TOCNode(id: block.id, title: text, blockID: block.id, children: [])
                    if currentChapterId != nil {
                        currentChapterNodes.append(sectionNode)
                    } else if currentPartId != nil {
                        currentPartNodes.append(sectionNode)
                    } else {
                        rootNodes.append(sectionNode)
                    }
                }
            }
        }
        
        flushFallback()
        flushPart()
        
        return rootNodes
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
