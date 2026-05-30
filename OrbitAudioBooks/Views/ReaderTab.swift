import SwiftUI
import GRDB

struct ReaderTab: View {
    let folderURL: URL
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settingsManager

    @State private var viewModel: ReaderFeedViewModel?
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showChapterPickerForBlockID: String? = nil
    @State private var showCardColorPickerForBlockID: String? = nil
    @State private var readerSettings = ReaderSettings(
        fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8"
    )

    var body: some View {
        VStack(spacing: 0) {
            if let vm = viewModel {
                ReaderHeaderView(
                    searchText: $searchText,
                    chapterTitle: "EPUB Reader",
                    onSettingsTap: { showSettings = true }
                )

                ReaderFeedCollectionView(
                    cards: .constant(vm.cards),
                    activeBlockID: .constant(vm.activeBlockID),
                    settings: readerSettings,
                    onTapBlock: { blockID in
                        seekToBlock(blockID)
                    },
                    onContextMenu: { blockID, kind in
                        buildContextMenu(blockID: blockID, kind: kind)
                    }
                )
            } else {
                Spacer()
                ProgressView("Loading EPUB...")
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
        .sheet(item: chapterPickerBinding) { ident in
            let blockID = ident.id
            ChapterPickerSheet(
                chapters: model.state.chapters,
                onSelect: { chapter in
                    alignBlock(blockID, to: chapter.startSeconds, source: .chapterBoundary)
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

    private func loadViewModel() {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let vm = ReaderFeedViewModel(audiobookID: audiobookID, db: db.writer)
        vm.reload()
        self.viewModel = vm
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

    private func alignBlock(_ blockID: String, to time: TimeInterval, source: AlignmentAnchorRecord.Source) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.moveBlockToCurrentTime(blockID: blockID, time: time)
            viewModel?.reload()
        } catch {
            // Alignment failure is logged by AlignmentService
        }
    }

    private func buildContextMenu(blockID: String, kind: EPubBlockRecord.Kind?) -> UIContextMenuConfiguration? {
        let isHeading = kind == .heading

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions: [UIAction] = []

            let changeColorAction = UIAction(
                title: "Change Color", image: UIImage(systemName: "paintpalette")
            ) { _ in
                DispatchQueue.main.async {
                    showCardColorPickerForBlockID = blockID
                }
            }
            actions.append(changeColorAction)

            let alignNowAction = UIAction(
                title: "Align to Now", image: UIImage(systemName: "location.fill")
            ) { [weak model] _ in
                guard let model else { return }
                alignBlock(blockID, to: model.currentPlaybackTime, source: .moveToNow)
            }
            actions.append(alignNowAction)

            let alignFiveAction = UIAction(
                title: "Align to 5s Ago", image: UIImage(systemName: "gobackward.5")
            ) { [weak model] _ in
                guard let model else { return }
                alignBlock(blockID, to: max(0, model.currentPlaybackTime - 5.0), source: .moveToNow)
            }
            actions.append(alignFiveAction)

            if isHeading {
                let alignChapterAction = UIAction(
                    title: "Align to Chapter", image: UIImage(systemName: "text.book.closed")
                ) { _ in
                    showChapterPickerForBlockID = blockID
                }
                actions.append(alignChapterAction)
            }

            return UIMenu(title: "", children: actions)
        }
    }
}
