#if os(iOS)
    // SPDX-License-Identifier: GPL-3.0-or-later
    import SwiftUI
    import GRDB
    import UIKit
    import os.log

    // MARK: - ReaderTab Alignment & Context Menu Operations

    extension ReaderTab {

        // MARK: Alignment Operations

        func alignBlock(
            _ blockID: String, to time: TimeInterval, source: AlignmentAnchorRecord.Source
        ) {
            guard let db = model.databaseService else { return }
            let audiobookID = folderURL.absoluteString
            let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
            do {
                try alignmentService.moveBlockToCurrentTime(blockID: blockID, time: time)
                viewModel?.reload()

                // Haptic confirmation
                haptic.impactOccurred()

                // Visual pulse on the aligned card
                pulseResetTask?.cancel()
                pulseBlockID = blockID
                pulseResetTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(600))
                    } catch {
                        return
                    }

                    guard !Task.isCancelled else { return }
                    if pulseBlockID == blockID {
                        pulseBlockID = nil
                    }
                    pulseResetTask = nil
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

                    if let exactTime = try? await autoService.fineTuneManualAlignment(
                        blockID: blockID, around: time)
                    {
                        try? alignmentService.moveBlockToCurrentTime(
                            blockID: blockID, time: exactTime)
                        await MainActor.run {
                            viewModel?.reload()
                            Haptic.play(.medium)
                        }
                    }
                }
            } catch {
                Haptic.play(.rigid)
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
                logger.error(
                    "Failed to hide block (blockID: \(blockID)): \(error.localizedDescription)")
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
                logger.error(
                    "Failed to unhide block (blockID: \(blockID)): \(error.localizedDescription)")
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
                logger.error(
                    "Failed to hide chapter (chapterIndex: \(chapterIndex)): \(error.localizedDescription)"
                )
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
                Haptic.play(.rigid)
            }
        }

        func startAutoAlignment(model: PlayerModel) {
            guard let db = model.databaseService else { return }
            guard let vm = viewModel else { return }
            let audiobookID = folderURL.absoluteString

            let chapters = model.alignmentPickerChapters
            let blocks = (try? EPubBlockDAO(db: db.writer).blocks(for: audiobookID)) ?? []

            guard !chapters.isEmpty, !blocks.isEmpty else {
                vm.showAutoAlignmentFailedAlert = true
                // Kept on one line (fits lineLength 100) so the localized-string
                // guard in LocalizationFormattingTests matches the exact call.
                let message = String(localized: "No chapters or EPUB blocks found.")
                vm.autoAlignmentErrorMessage = message
                return
            }

            vm.autoAlignmentState.reset()

            let autoService = AutoAlignmentService(
                db: db.writer,
                audiobookID: audiobookID,
                audioEngine: model.audioEngine,
                state: vm.autoAlignmentState
            )

            vm.showAutoAlignmentProgress = true
            vm.autoAlignmentTask = autoService.startAutoAlignment(
                chapters: chapters, blocks: blocks)

            Task { @MainActor in
                do {
                    try await vm.autoAlignmentTask?.value
                    vm.reload()
                    haptic.impactOccurred()
                } catch is CancellationError {
                    // User cancelled — clean exit.
                } catch {
                    vm.showAutoAlignmentFailedAlert = true
                    vm.autoAlignmentErrorMessage = error.localizedDescription
                }
                vm.autoAlignmentTask = nil
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
                Haptic.play(.rigid)
            }
        }

        // MARK: Context Menu Builder

        func buildAccessibilityActions(block: EPubBlockRecord) -> [UIAccessibilityCustomAction] {
            let blockID = block.id
            let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
            let status = viewModel?.alignmentStatusByBlockID[blockID]

            var actions: [UIAccessibilityCustomAction] = []

            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Auto-Align Chapters")) {
                    [weak model] _ in
                    guard let model else { return false }
                    startAutoAlignment(model: model)
                    return true
                })

            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Change Color")) { _ in
                    showCardColorPickerForBlockID = blockID
                    return true
                })

            if kind == .heading {
                actions.append(
                    UIAccessibilityCustomAction(name: String(localized: "Set Chapter Theme")) { _ in
                        showChapterThemePickerForBlockID = blockID
                        return true
                    })
            }

            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Align to Now")) {
                    [weak model] _ in
                    guard let model else { return false }
                    alignBlock(blockID, to: model.currentPlaybackTime, source: .moveToNow)
                    return true
                })

            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Align to 5s Ago")) {
                    [weak model] _ in
                    guard let model else { return false }
                    alignBlock(
                        blockID, to: max(0, model.currentPlaybackTime - 5.0), source: .moveToNow)
                    return true
                })

            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Align to Chapter Start")) {
                    _ in
                    showChapterPickerForBlockID = blockID
                    return true
                })

            if let chapterIndex = block.chapterIndex {
                actions.append(
                    UIAccessibilityCustomAction(
                        name: String(
                            localized: "notInAudioWholeChapterAction",
                            defaultValue: "Not in Audio, Whole Chapter")
                    ) { _ in
                        hideChapter(chapterIndex)
                        return true
                    })
            }

            if block.isHidden {
                actions.append(
                    UIAccessibilityCustomAction(name: String(localized: "Include in Audio")) { _ in
                        unhideBlock(blockID)
                        return true
                    })
            } else {
                actions.append(
                    UIAccessibilityCustomAction(
                        name: String(
                            localized: "notInAudioThisParagraphAction",
                            defaultValue: "Not in Audio, This Paragraph")
                    ) { _ in
                        hideBlock(blockID)
                        return true
                    })
            }

            if status == "lockedAnchor" {
                actions.append(
                    UIAccessibilityCustomAction(name: String(localized: "Erase Anchor")) { _ in
                        eraseAnchor(blockID)
                        return true
                    })
            }

            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Reset Alignment")) { _ in
                    resetAlignment()
                    return true
                })

            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Save Bookmark")) {
                    [weak model] _ in
                    guard let model else { return false }
                    saveBookmark(block: block, model: model)
                    return true
                })

            if let text = block.text, !text.isEmpty {
                actions.append(
                    UIAccessibilityCustomAction(name: String(localized: "Copy Text")) { _ in
                        UIPasteboard.general.string = text
                        return true
                    })
            }

            if kind == .image {
                actions.append(
                    UIAccessibilityCustomAction(name: String(localized: "Save Image")) { _ in
                        saveImageToCameraRoll(block: block)
                        return true
                    })
            }

            return actions
        }

        func buildContextMenu(
            block: EPubBlockRecord,
            word: ReaderFeedCollectionView.ReaderWordHit? = nil
        ) -> UIContextMenuConfiguration? {
            let blockID = block.id
            let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
            let status = viewModel?.alignmentStatusByBlockID[blockID]

            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                var actions: [UIAction] = []

                // ── Word actions (prepended when a word is resolved under the finger) ──
                if let hit = word {
                    let term = hit.word
                    if DictionaryLookupPresenter.hasDefinition(for: term) {
                        actions.append(
                            UIAction(
                                title: String(localized: "Look Up \u{201C}\(term)\u{201D}"),
                                image: UIImage(systemName: "character.book.closed")
                            ) { _ in
                                DictionaryLookupPresenter.present(term: term)
                            })
                    }
                    actions.append(
                        UIAction(
                            title: String(localized: "Save \u{201C}\(term)\u{201D}"),
                            image: UIImage(systemName: "text.badge.plus")
                        ) { [weak model] _ in
                            saveVocabularyWord(hit, in: block, model: model)
                        })
                }

                let autoAlignAction = UIAction(
                    title: String(localized: "Auto-Align Chapters"),
                    image: UIImage(systemName: "wand.and.stars")
                ) { [weak model] _ in
                    guard let model else { return }
                    startAutoAlignment(model: model)
                }
                actions.append(autoAlignAction)

                let changeColorAction = UIAction(
                    title: String(localized: "Change Color"),
                    image: UIImage(systemName: "paintpalette")
                ) { _ in
                    Task { @MainActor in
                        showCardColorPickerForBlockID = blockID
                    }
                }
                actions.append(changeColorAction)

                if kind == .heading {
                    let themeChapterAction = UIAction(
                        title: String(localized: "Set Chapter Theme"),
                        image: UIImage(systemName: "paintpalette.fill")
                    ) { _ in
                        Task { @MainActor in
                            showChapterThemePickerForBlockID = blockID
                        }
                    }
                    actions.append(themeChapterAction)
                }

                let alignNowAction = UIAction(
                    title: String(localized: "Align to Now"),
                    image: UIImage(systemName: "location.fill")
                ) { [weak model] _ in
                    guard let model else { return }
                    alignBlock(blockID, to: model.currentPlaybackTime, source: .moveToNow)
                }
                actions.append(alignNowAction)

                let alignFiveAction = UIAction(
                    title: String(localized: "Align to 5s Ago"),
                    image: UIImage(systemName: "gobackward.5")
                ) { [weak model] _ in
                    guard let model else { return }
                    alignBlock(
                        blockID, to: max(0, model.currentPlaybackTime - 5.0), source: .moveToNow)
                }
                actions.append(alignFiveAction)

                let alignChapterAction = UIAction(
                    title: String(localized: "Align to Chapter Start"),
                    image: UIImage(systemName: "text.book.closed")
                ) { _ in
                    showChapterPickerForBlockID = blockID
                }
                actions.append(alignChapterAction)

                if let chapterIndex = block.chapterIndex {
                    let skipChapterAction = UIAction(
                        title: String(
                            localized: "notInAudioWholeChapterContextMenu",
                            defaultValue: "Not in Audio (Whole Chapter)"),
                        image: UIImage(systemName: "speaker.slash.fill")
                    ) { _ in
                        hideChapter(chapterIndex)
                    }
                    actions.append(skipChapterAction)
                }

                if block.isHidden {
                    let unhideBlockAction = UIAction(
                        title: String(localized: "Include in Audio"),
                        image: UIImage(systemName: "speaker.wave.2.fill")
                    ) { _ in
                        unhideBlock(blockID)
                    }
                    actions.append(unhideBlockAction)
                } else {
                    let skipBlockAction = UIAction(
                        title: String(
                            localized: "notInAudioThisParagraphContextMenu",
                            defaultValue: "Not in Audio (This Paragraph)"),
                        image: UIImage(systemName: "speaker.slash")
                    ) { _ in
                        hideBlock(blockID)
                    }
                    actions.append(skipBlockAction)
                }

                if status == "lockedAnchor" {
                    let eraseAction = UIAction(
                        title: String(localized: "Erase Anchor"),
                        image: UIImage(systemName: "link.badge.minus"), attributes: .destructive
                    ) { _ in
                        eraseAnchor(blockID)
                    }
                    actions.append(eraseAction)
                }

                let resetAction = UIAction(
                    title: String(localized: "Reset Alignment"),
                    image: UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath"),
                    attributes: .destructive
                ) { _ in
                    resetAlignment()
                }
                actions.append(resetAction)

                let saveBookmarkAction = UIAction(
                    title: String(localized: "Save Bookmark"),
                    image: UIImage(systemName: "bookmark.fill")
                ) { [weak model] _ in
                    guard let model else { return }
                    saveBookmark(block: block, model: model)
                }
                actions.append(saveBookmarkAction)

                if let text = block.text, !text.isEmpty {
                    let copyAction = UIAction(
                        title: String(localized: "Copy Text"),
                        image: UIImage(systemName: "doc.on.doc")
                    ) { _ in
                        UIPasteboard.general.string = text
                    }
                    actions.append(copyAction)
                }

                if kind == .image {
                    let saveImageAction = UIAction(
                        title: String(localized: "Save Image"),
                        image: UIImage(systemName: "square.and.arrow.down")
                    ) { _ in
                        saveImageToCameraRoll(block: block)
                    }
                    actions.append(saveImageAction)
                }

                // Audit D1: long-press is the timestamp reveal for inactive cards.
                let timeString = viewModel?.audioStartTimeByBlockID[blockID]
                    .map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
                let menuTitle = timeString.map { String(localized: "Audio position \($0)") } ?? ""
                return UIMenu(title: menuTitle, children: actions)
            }
        }

        // MARK: Vocabulary Word Save

        func saveVocabularyWord(
            _ hit: ReaderFeedCollectionView.ReaderWordHit,
            in block: EPubBlockRecord,
            model: PlayerModel?
        ) {
            guard let model, let db = model.databaseService else { return }
            let audiobookID = folderURL.absoluteString
            // Pro cap (D6)
            guard freeTierGate.canCreateFlashcards(adding: 1) else {
                model.paywallContext = .flashcardCap
                model.showPaywall = true
                return
            }
            let dao = FlashcardDAO(db: db.writer)
            // Dedupe (D7): re-surface existing card with a light haptic, no duplicate
            if (try? dao.vocabularyCard(for: audiobookID, word: hit.word)) != nil {
                Haptic.play(.light)
                return
            }
            // Audio anchor: prefer per-word timing from the cache, fall back to block start
            let times = viewModel?.wordTiming(blockID: hit.blockID, wordIndex: hit.wordIndex)
            let text = block.text ?? ""
            let ranges = WordTokenizer.wordRanges(in: text)
            let nsRange: NSRange
            if hit.wordIndex < ranges.count {
                nsRange = NSRange(ranges[hit.wordIndex], in: text)
            } else {
                nsRange = NSRange(location: NSNotFound, length: 0)
            }
            let context = WordSentenceContext.sentence(containing: nsRange, in: text)
            let audioStart =
                times?.start
                ?? viewModel?.audioStartTime(for: hit.blockID, audiobookID: audiobookID)
                ?? 0
            let card = VocabularyCardBuilder.make(
                id: UUID().uuidString,
                audiobookID: audiobookID,
                word: hit.word,
                contextSentence: context.isEmpty ? nil : context,
                blockID: hit.blockID,
                audioStart: audioStart,
                audioEnd: times?.end,
                createdAt: Date().ISO8601Format()
            )
            do {
                try dao.insert(card)
                Haptic.play(.medium)
            } catch {
                logger.error("Failed to save vocabulary word '\(hit.word)': \(error)")
                Haptic.play(.rigid)
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
                    try Row.fetchOne(
                        db,
                        sql: """
                            SELECT audio_start_time FROM timeline_item
                            WHERE epub_block_id = ? AND audiobook_id = ?
                            LIMIT 1
                            """, arguments: [block.id, audiobookID]
                    )?["audio_start_time"]
                }), startTime >= 0 {
                    mediaTime = startTime
                }
            } catch {
                logger.error(
                    "Failed to query timeline audio_start_time (blockID: \(block.id)): \(error.localizedDescription)"
                )
            }

            let note = block.text?.prefix(200).description ?? ""

            let bookmark = BookmarkRecord(
                id: UUID().uuidString,
                audiobookID: audiobookID,
                trackID: nil,
                title: String(localized: "Bookmarked text"),
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

#endif
