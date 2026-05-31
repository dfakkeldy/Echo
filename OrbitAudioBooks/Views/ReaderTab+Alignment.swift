import SwiftUI
import GRDB
import UIKit
import os.log

// MARK: - ReaderTab Alignment & Context Menu Operations

extension ReaderTab {

    // MARK: Alignment Operations

    func alignBlock(_ blockID: String, to time: TimeInterval, source: AlignmentAnchorRecord.Source) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.moveBlockToCurrentTime(blockID: blockID, time: time)
            viewModel?.reload()

            // Haptic confirmation
            haptic.impactOccurred()

            // Visual pulse on the aligned card
            pulseBlockID = blockID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if pulseBlockID == blockID {
                    pulseBlockID = nil
                }
            }

            // Phase 3: Auto-transcription for Manual Alignments (Fine-Tuning)
            Task {
                let autoState = AutoAlignmentState()
                let autoService = AutoAlignmentService(
                    db: db.writer,
                    audiobookID: audiobookID,
                    audioEngine: model.audioEngine,
                    state: autoState
                )

                if let exactTime = try? await autoService.fineTuneManualAlignment(blockID: blockID, around: time) {
                    try? alignmentService.moveBlockToCurrentTime(blockID: blockID, time: exactTime)
                    await MainActor.run {
                        viewModel?.reload()
                        let successHaptic = UINotificationFeedbackGenerator()
                        successHaptic.notificationOccurred(.success)
                    }
                }
            }
        } catch {
            let errorHaptic = UINotificationFeedbackGenerator()
            errorHaptic.notificationOccurred(.error)
        }
    }

    func alignChapterEnd(_ blockID: String, chapterIndex: Int?, to time: TimeInterval) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.anchorChapterEnd(blockID: blockID, chapterIndex: chapterIndex ?? 0, time: time)
            viewModel?.reload()
            haptic.impactOccurred()
        } catch {
            logger.error("Failed to anchor chapter end (blockID: \(blockID), chapterIndex: \(chapterIndex ?? 0)): \(error.localizedDescription)")
        }
    }

    func hideBlock(_ blockID: String) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.hideBlock(blockID: blockID, reason: "Manual skip")
            viewModel?.reload()
        } catch {
            logger.error("Failed to hide block (blockID: \(blockID)): \(error.localizedDescription)")
        }
    }

    func unhideBlock(_ blockID: String) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.unhideBlock(blockID: blockID)
            viewModel?.reload()
        } catch {
            logger.error("Failed to unhide block (blockID: \(blockID)): \(error.localizedDescription)")
        }
    }

    func hideChapter(_ chapterIndex: Int) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.hideChapter(chapterIndex: chapterIndex, reason: "Manual skip")
            viewModel?.reload()
        } catch {
            logger.error("Failed to hide chapter (chapterIndex: \(chapterIndex)): \(error.localizedDescription)")
        }
    }

    func eraseAnchor(_ blockID: String) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.eraseAnchor(blockID: blockID)
            viewModel?.reload()
            haptic.impactOccurred()
        } catch {
            let errorHaptic = UINotificationFeedbackGenerator()
            errorHaptic.notificationOccurred(.error)
        }
    }

    func startAutoAlignment(model: PlayerModel) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString

        let chapters = model.alignmentPickerChapters
        let blocks = (try? EPubBlockDAO(db: db.writer).blocks(for: audiobookID)) ?? []

        guard !chapters.isEmpty, !blocks.isEmpty else {
            showAutoAlignmentFailedAlert = true
            autoAlignmentErrorMessage = "No chapters or EPUB blocks found."
            return
        }

        autoAlignmentState.reset()
        viewModel?.autoAlignmentState = autoAlignmentState

        let autoService = AutoAlignmentService(
            db: db.writer,
            audiobookID: audiobookID,
            audioEngine: model.audioEngine,
            state: autoAlignmentState
        )

        showAutoAlignmentProgress = true
        autoAlignmentTask = autoService.startAutoAlignment(chapters: chapters, blocks: blocks)

        Task { @MainActor in
            do {
                try await autoAlignmentTask?.value
                viewModel?.reload()
                haptic.impactOccurred()
            } catch is CancellationError {
                // User cancelled — clean exit.
            } catch {
                showAutoAlignmentFailedAlert = true
                autoAlignmentErrorMessage = error.localizedDescription
            }
            autoAlignmentTask = nil
        }
    }

    func resetAlignment() {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.resetAlignment()
            viewModel?.reload()
            haptic.impactOccurred()
        } catch {
            let errorHaptic = UINotificationFeedbackGenerator()
            errorHaptic.notificationOccurred(.error)
        }
    }

    // MARK: Context Menu Builder

    func buildContextMenu(block: EPubBlockRecord) -> UIContextMenuConfiguration? {
        let blockID = block.id
        let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
        let status = viewModel?.alignmentStatusByBlockID[blockID]

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions: [UIAction] = []

            let autoAlignAction = UIAction(
                title: "Auto-Align Chapters", image: UIImage(systemName: "wand.and.stars")
            ) { [weak model] _ in
                guard let model else { return }
                startAutoAlignment(model: model)
            }
            actions.append(autoAlignAction)

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

            let alignChapterAction = UIAction(
                title: "Align to Chapter Start", image: UIImage(systemName: "text.book.closed")
            ) { _ in
                showChapterPickerForBlockID = blockID
            }
            actions.append(alignChapterAction)

            let alignChapterEndAction = UIAction(
                title: "Align to Chapter End", image: UIImage(systemName: "text.book.closed.fill")
            ) { _ in
                showEndChapterPickerForBlockID = blockID
            }
            actions.append(alignChapterEndAction)

            if let chapterIndex = block.chapterIndex {
                let skipChapterAction = UIAction(
                    title: "Not in Audio (Whole Chapter)", image: UIImage(systemName: "speaker.slash.fill")
                ) { _ in
                    hideChapter(chapterIndex)
                }
                actions.append(skipChapterAction)
            }

            if block.isHidden {
                let unhideBlockAction = UIAction(
                    title: "Include in Audio", image: UIImage(systemName: "speaker.wave.2.fill")
                ) { _ in
                    unhideBlock(blockID)
                }
                actions.append(unhideBlockAction)
            } else {
                let skipBlockAction = UIAction(
                    title: "Not in Audio (This Paragraph)", image: UIImage(systemName: "speaker.slash")
                ) { _ in
                    hideBlock(blockID)
                }
                actions.append(skipBlockAction)
            }

            if status == "lockedAnchor" {
                let eraseAction = UIAction(
                    title: "Erase Anchor", image: UIImage(systemName: "link.badge.minus"), attributes: .destructive
                ) { _ in
                    eraseAnchor(blockID)
                }
                actions.append(eraseAction)
            }

            let resetAction = UIAction(
                title: "Reset Alignment", image: UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath"), attributes: .destructive
            ) { _ in
                resetAlignment()
            }
            actions.append(resetAction)

            let saveBookmarkAction = UIAction(
                title: "Save Bookmark", image: UIImage(systemName: "bookmark.fill")
            ) { [weak model] _ in
                guard let model else { return }
                saveBookmark(block: block, model: model)
            }
            actions.append(saveBookmarkAction)

            if let text = block.text, !text.isEmpty {
                let copyAction = UIAction(
                    title: "Copy Text", image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = text
                }
                actions.append(copyAction)
            }

            if kind == .image {
                let saveImageAction = UIAction(
                    title: "Save Image", image: UIImage(systemName: "square.and.arrow.down")
                ) { _ in
                    saveImageToCameraRoll(block: block)
                }
                actions.append(saveImageAction)
            }

            return UIMenu(title: "", children: actions)
        }
    }

    // MARK: Bookmark Creation

    func saveBookmark(block: EPubBlockRecord, model: PlayerModel) {
        guard let db = model.databaseService else { return }
        let bookmarkDAO = BookmarkDAO(db: db.writer)
        let nowString = AlignmentService.isoFormatter.string(from: Date())

        var mediaTime = model.currentPlaybackTime
        let audiobookID = folderURL.absoluteString
        do {
            if let startTime: Double = try db.writer.read({ db in
                try Row.fetchOne(db, sql: """
                    SELECT audio_start_time FROM timeline_item
                    WHERE epub_block_id = ? AND audiobook_id = ?
                    LIMIT 1
                    """, arguments: [block.id, audiobookID]
                )?["audio_start_time"]
            }), startTime >= 0 {
                mediaTime = startTime
            }
        } catch {
            logger.error("Failed to query timeline audio_start_time (blockID: \(block.id)): \(error.localizedDescription)")
        }

        let note = block.text?.prefix(200).description ?? ""

        let bookmark = BookmarkRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            trackID: nil,
            title: "Bookmarked text",
            mediaTimestamp: mediaTime,
            note: note.isEmpty ? nil : note,
            voiceMemoPath: nil,
            imagePath: block.imagePath,
            isEnabled: true,
            playlistPosition: nil,
            createdAt: nowString,
            modifiedAt: nowString
        )

        do {
            try bookmarkDAO.insert(bookmark)
        } catch {
            logger.error("Failed to save bookmark: \(error)")
        }
    }
}
