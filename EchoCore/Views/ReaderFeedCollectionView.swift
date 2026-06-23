// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// UIViewRepresentable wrapping a UICollectionView that renders the EPUB reader feed.
struct ReaderFeedCollectionView: UIViewRepresentable {
    var sections: [ReaderCardSection]
    @Binding var activeBlockID: String?
    /// The currently spoken word (for karaoke), sourced read-only from the view
    /// model. Plain value (not a `@Binding`): data flows one way (VM → cell) and
    /// the collection never writes it back, so a binding would only loosen the
    /// view model's `private(set)` for nothing.
    var activeWord: (blockID: String, index: Int)? = nil
    @Binding var isHeaderVisible: Bool
    @Binding var autoScrollEnabled: Bool
    @Binding var topPartTitle: String?
    @Binding var topChapterTitle: String?
    @Binding var topSectionTitle: String?
    @Binding var topChapterThemeColor: String?
    let settings: ReaderSettings
    var alignmentStatusByBlockID: [String: String] = [:]
    var audioStartTimeByBlockID: [String: TimeInterval] = [:]
    var chapterHasAudio: [Int: Bool] = [:]
    var chapterThemeColorByKey: [Int: String] = [:]
    var openChapterKey: Int? = nil
    var onToggleChapter: ((Int) -> Void)?
    var searchQuery: String? = nil
    var pulseBlockID: String? = nil
    var forceScrollBlockID: String? = nil
    var forceScrollTrigger: Int = 0
    var onTapBlock: ((String) -> Void)?
    var onContextMenu: ((EPubBlockRecord) -> UIContextMenuConfiguration?)?
    var onChapterHeaderContextMenu: ((Int) -> UIContextMenuConfiguration?)?
    var offState: ((Int) -> ChapterOffState)?
    var onPlayMemo: ((VoiceMemoRecord) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTapBlock: onTapBlock,
            onContextMenu: onContextMenu,
            isHeaderVisible: $isHeaderVisible,
            autoScrollEnabled: $autoScrollEnabled,
            topPartTitle: $topPartTitle,
            topChapterTitle: $topChapterTitle,
            topSectionTitle: $topSectionTitle,
            topChapterThemeColor: $topChapterThemeColor
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(200)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 6
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 8, leading: 12, bottom: 8, trailing: 12)
            return section
        }

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        // Native content-inset adjustment: the collection adopts the SwiftUI
        // safe-area insets (status bar + the reader header / dock clearance that
        // ReaderTab supplies via `.safeAreaInset`). No manual inset math here.
        collectionView.backgroundColor = .clear
        collectionView.delegate = context.coordinator

        collectionView.register(
            HeadingCardCell.self, forCellWithReuseIdentifier: HeadingCardCell.reuseIdentifier)
        collectionView.register(
            ParagraphCardCell.self, forCellWithReuseIdentifier: ParagraphCardCell.reuseIdentifier)
        collectionView.register(
            ImageCardCell.self, forCellWithReuseIdentifier: ImageCardCell.reuseIdentifier)
        collectionView.register(
            ChapterDividerCell.self, forCellWithReuseIdentifier: ChapterDividerCell.reuseIdentifier)
        collectionView.register(
            BookmarkFeedCell.self, forCellWithReuseIdentifier: BookmarkFeedCell.reuseIdentifier)
        collectionView.register(
            AnkiCardFeedCell.self, forCellWithReuseIdentifier: AnkiCardFeedCell.reuseIdentifier)
        collectionView.register(
            NoteFeedCell.self, forCellWithReuseIdentifier: NoteFeedCell.reuseIdentifier)
        collectionView.register(
            VoiceMemoFeedCell.self,
            forCellWithReuseIdentifier: VoiceMemoFeedCell.reuseIdentifier)

        context.coordinator.dataSource = makeDataSource(for: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.onTapBlock = onTapBlock
        context.coordinator.onContextMenu = onContextMenu
        context.coordinator.onChapterHeaderContextMenu = onChapterHeaderContextMenu
        context.coordinator.onPlayMemo = onPlayMemo
        context.coordinator.offState = offState
        context.coordinator.settings = settings
        context.coordinator.onToggleChapter = onToggleChapter
        context.coordinator.chapterHasAudio = chapterHasAudio
        context.coordinator.chapterThemeColorByKey = chapterThemeColorByKey
        let statusChanged = alignmentStatusByBlockID != context.coordinator.alignmentStatusByBlockID
        let startTimesChanged =
            audioStartTimeByBlockID != context.coordinator.audioStartTimeByBlockID

        context.coordinator.alignmentStatusByBlockID = alignmentStatusByBlockID
        context.coordinator.audioStartTimeByBlockID = audioStartTimeByBlockID

        if statusChanged || startTimesChanged {
            if let dataSource = context.coordinator.dataSource {
                for cell in collectionView.visibleCells {
                    if let indexPath = collectionView.indexPath(for: cell),
                        let itemID = dataSource.itemIdentifier(for: indexPath),
                        itemID.hasPrefix("b-")
                    {
                        let blockID = String(itemID.dropFirst(2))
                        let timeString =
                            audioStartTimeByBlockID[blockID].map {
                                Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
                            } ?? "None"
                        let isAnchored = alignmentStatusByBlockID[blockID] == "lockedAnchor"

                        if let headingCell = cell as? HeadingCardCell {
                            headingCell.setManuallyAligned(isAnchored, timeString: timeString)
                        } else if let paraCell = cell as? ParagraphCardCell {
                            paraCell.setManuallyAligned(isAnchored, timeString: timeString)
                        }
                    }
                }
            }
        }

        context.coordinator.activeBlockID = activeBlockID
        context.coordinator.searchQuery = searchQuery

        if let pulseID = pulseBlockID, pulseID != context.coordinator.pulseBlockID {
            context.coordinator.pulseBlockID = pulseID
            context.coordinator.pulseCell(for: pulseID, in: collectionView)
        } else if pulseBlockID == nil {
            context.coordinator.pulseBlockID = nil
        }

        if let forceID = forceScrollBlockID,
            forceID != context.coordinator.lastForceScrolledID
                || forceScrollTrigger != context.coordinator.lastForceScrollTrigger
        {
            context.coordinator.lastForceScrolledID = forceID
            context.coordinator.lastForceScrollTrigger = forceScrollTrigger
            // Resolve the index path inside the Task, not synchronously here: when the
            // scroll target's chapter was just expanded (its blocks are added by the
            // snapshot apply later in this same updateUIView pass), a synchronous lookup
            // would miss the not-yet-applied item and silently skip the scroll. The Task
            // runs after this pass returns, by which point applySnapshot has updated the
            // data source's snapshot, so the lookup sees the freshly-expanded block.
            Task { @MainActor in
                if let indexPath = context.coordinator.dataSource?.indexPath(
                    for: "b-\(forceID)")
                {
                    collectionView.scrollToItem(
                        at: indexPath, at: .centeredVertically, animated: true)
                }
            }
        }

        let previousOpenKey = context.coordinator.openChapterKey
        let openKeyChanged = openChapterKey != previousOpenKey
        context.coordinator.openChapterKey = openChapterKey

        if sections != context.coordinator.sections {
            let wasEmpty = context.coordinator.sections.isEmpty
            context.coordinator.sections = sections
            let headerReconfigures =
                openKeyChanged
                ? [previousOpenKey, openChapterKey].compactMap { $0.map { "ch-\($0)" } } : []
            context.coordinator.applySnapshot(
                animated: !wasEmpty, in: collectionView, reconfiguring: headerReconfigures)

            if wasEmpty, let firstSection = sections.first,
                let title = firstSection.headingStack.first
            {
                Task { @MainActor in
                    self.topChapterTitle = title
                }
            }
        } else if openKeyChanged {
            // Same section structure but a header chevron must flip (rare; e.g. a
            // chapter with no extra sub-sections).
            context.coordinator.applySnapshot(
                animated: true, in: collectionView,
                reconfiguring: [previousOpenKey, openChapterKey].compactMap {
                    $0.map { "ch-\($0)" }
                }
            )
        }

        context.coordinator.updateActiveBlock(activeBlockID, in: collectionView)

        // Karaoke: keep the coordinator's word in sync so freshly-dequeued cells
        // render the right word, then retint the on-screen active cell — throttled
        // to ~12 Hz so word-rate updates don't thrash the visible cell.
        let blockChanged = activeWord?.blockID != context.coordinator.activeWord?.blockID
        let wordChanged =
            blockChanged || activeWord?.index != context.coordinator.activeWord?.index
        context.coordinator.activeWord = activeWord
        if wordChanged {
            let now = CACurrentMediaTime()
            // Always process a block change (or a clear to nil) immediately so the
            // previous paragraph's highlight is removed promptly; only throttle the
            // within-paragraph word steps to ~12 Hz.
            if blockChanged || now - context.coordinator.lastWordTick >= 0.08 {
                context.coordinator.lastWordTick = now
                context.coordinator.updateActiveWord(activeWord, in: collectionView)
            }
        }
    }

    private func makeDataSource(for collectionView: UICollectionView)
        -> UICollectionViewDiffableDataSource<String, String>
    {
        let ds = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView)
        {
            collectionView, indexPath, itemID in
            guard let coordinator = collectionView.delegate as? Coordinator else {
                return UICollectionViewCell()
            }
            return coordinator.cell(for: itemID, at: indexPath, collectionView: collectionView)
        }
        return ds
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UICollectionViewDelegate {
        var onTapBlock: ((String) -> Void)?
        var onContextMenu: ((EPubBlockRecord) -> UIContextMenuConfiguration?)?
        var onChapterHeaderContextMenu: ((Int) -> UIContextMenuConfiguration?)?
        var offState: ((Int) -> ChapterOffState)?
        var onPlayMemo: ((VoiceMemoRecord) -> Void)?
        var isHeaderVisible: Binding<Bool>
        var autoScrollEnabled: Binding<Bool>
        var topPartTitle: Binding<String?>
        var topChapterTitle: Binding<String?>
        var topSectionTitle: Binding<String?>
        var topChapterThemeColor: Binding<String?>
        var settings: ReaderSettings = ReaderSettings(
            fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8", appFont: "System")
        var alignmentStatusByBlockID: [String: String] = [:]
        var audioStartTimeByBlockID: [String: TimeInterval] = [:]
        var chapterHasAudio: [Int: Bool] = [:]
        var chapterThemeColorByKey: [Int: String] = [:]
        var openChapterKey: Int?
        var onToggleChapter: ((Int) -> Void)?
        var searchQuery: String? = nil
        var pulseBlockID: String? = nil
        var dataSource: UICollectionViewDiffableDataSource<String, String>?
        var sections: [ReaderCardSection] = []
        var activeBlockID: String?
        var activeWord: (blockID: String, index: Int)?
        /// The block whose karaoke word is currently highlighted on screen, so
        /// the next word-move can clear it (otherwise the previous paragraph's
        /// last word stays lit when playback crosses a paragraph boundary).
        var lastHighlightedWordBlockID: String?
        /// Throttles karaoke word retints to ~12 Hz so word-rate updates don't
        /// thrash the active cell. `updateUIView` fires far more often than the
        /// human eye needs the highlight to move.
        var lastWordTick: TimeInterval = 0
        var lastScrolledBlockID: String?
        var lastForceScrolledID: String?
        var lastForceScrollTrigger: Int = 0

        init(
            onTapBlock: ((String) -> Void)?,
            onContextMenu: ((EPubBlockRecord) -> UIContextMenuConfiguration?)?,
            isHeaderVisible: Binding<Bool>, autoScrollEnabled: Binding<Bool>,
            topPartTitle: Binding<String?>, topChapterTitle: Binding<String?>,
            topSectionTitle: Binding<String?>, topChapterThemeColor: Binding<String?>
        ) {
            self.onTapBlock = onTapBlock
            self.onContextMenu = onContextMenu
            self.isHeaderVisible = isHeaderVisible
            self.autoScrollEnabled = autoScrollEnabled
            self.topPartTitle = topPartTitle
            self.topChapterTitle = topChapterTitle
            self.topSectionTitle = topSectionTitle
            self.topChapterThemeColor = topChapterThemeColor
        }

        func card(for id: String) -> ReaderCardItem? {
            for section in sections {
                if let card = section.items.first(where: { $0.id == id }) {
                    return card
                }
            }
            return nil
        }

        func cell(for itemID: String, at indexPath: IndexPath, collectionView: UICollectionView)
            -> UICollectionViewCell
        {
            guard let item = card(for: itemID) else { return UICollectionViewCell() }
            switch item {
            case .chapterHeader(let title, let chapterIndex):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: ChapterDividerCell.reuseIdentifier, for: indexPath
                    ) as? ChapterDividerCell
                else { return UICollectionViewCell() }
                cell.configure(
                    title: title, hasAudio: chapterHasAudio[chapterIndex] ?? false,
                    isExpanded: openChapterKey == chapterIndex,
                    offState: offState?(chapterIndex) ?? .allOn)
                return cell

            case .bookmark(let record):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: BookmarkFeedCell.reuseIdentifier, for: indexPath
                    ) as? BookmarkFeedCell
                else { return UICollectionViewCell() }
                let tint = UIColor(hex: settings.cardTintHex) ?? UIColor.systemBackground
                cell.configure(with: record, tint: tint)
                return cell

            case .ankiCard(let card):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: AnkiCardFeedCell.reuseIdentifier, for: indexPath
                    ) as? AnkiCardFeedCell
                else { return UICollectionViewCell() }
                let tint = UIColor(hex: settings.cardTintHex) ?? UIColor.systemBackground
                cell.configure(with: card, tint: tint)
                return cell

            case .note(let note):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: NoteFeedCell.reuseIdentifier, for: indexPath
                    ) as? NoteFeedCell
                else { return UICollectionViewCell() }
                cell.configure(text: note.text)
                return cell

            case .voiceMemo(let memo):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: VoiceMemoFeedCell.reuseIdentifier, for: indexPath
                    ) as? VoiceMemoFeedCell
                else { return UICollectionViewCell() }
                let durationText: String
                if let d = memo.duration {
                    durationText =
                        "Voice memo · "
                        + Duration.seconds(d)
                        .formatted(.time(pattern: .minuteSecond))
                } else {
                    durationText = "Voice memo"
                }
                cell.configure(durationText: durationText) { [weak self] in
                    self?.onPlayMemo?(memo)
                }
                return cell

            case .block(let block):
                switch block.blockKind {
                case EPubBlockRecord.Kind.heading.rawValue:
                    guard
                        let headingCell = collectionView.dequeueReusableCell(
                            withReuseIdentifier: HeadingCardCell.reuseIdentifier, for: indexPath
                        ) as? HeadingCardCell
                    else { return UICollectionViewCell() }
                    let font = settings.uiFont(forTextStyle: .title3, weight: .semibold)
                    let cardTint =
                        UIColor(
                            hex: block.cardColor ?? block.chapterThemeColor ?? settings.cardTintHex)
                        ?? UIColor.systemBackground
                    let headingWordIdx =
                        (activeWord?.blockID == block.id) ? activeWord?.index : nil
                    headingCell.configure(
                        with: block, font: font, tint: cardTint,
                        isExplicitHighlight: block.cardColor != nil
                            || block.chapterThemeColor != nil, searchQuery: searchQuery,
                        highlightedWordIndex: headingWordIdx)
                    headingCell.isActiveBlock = (block.id == activeBlockID)
                    let timeString =
                        audioStartTimeByBlockID[block.id].map {
                            Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
                        } ?? "None"
                    let isAnchored = alignmentStatusByBlockID[block.id] == "lockedAnchor"
                    headingCell.setManuallyAligned(isAnchored, timeString: timeString)
                    return headingCell

                case EPubBlockRecord.Kind.image.rawValue:
                    guard
                        let imageCell = collectionView.dequeueReusableCell(
                            withReuseIdentifier: ImageCardCell.reuseIdentifier, for: indexPath
                        ) as? ImageCardCell
                    else { return UICollectionViewCell() }
                    let cardTint =
                        UIColor(
                            hex: block.cardColor ?? block.chapterThemeColor ?? settings.cardTintHex)
                        ?? UIColor.systemBackground
                    imageCell.configure(with: block, tint: cardTint)
                    return imageCell

                default:
                    guard
                        let paraCell = collectionView.dequeueReusableCell(
                            withReuseIdentifier: ParagraphCardCell.reuseIdentifier, for: indexPath
                        ) as? ParagraphCardCell
                    else { return UICollectionViewCell() }
                    let font = settings.uiFont(forTextStyle: .body, weight: .regular)
                    let cardTint =
                        UIColor(
                            hex: block.cardColor ?? block.chapterThemeColor ?? settings.cardTintHex)
                        ?? UIColor.systemBackground
                    let paraWordIdx =
                        (activeWord?.blockID == block.id) ? activeWord?.index : nil
                    paraCell.configure(
                        with: block, font: font, tint: cardTint, lineSpacing: settings.lineSpacing,
                        isExplicitHighlight: block.cardColor != nil
                            || block.chapterThemeColor != nil, searchQuery: searchQuery,
                        highlightedWordIndex: paraWordIdx)
                    paraCell.isActiveBlock = (block.id == activeBlockID)
                    let timeString =
                        audioStartTimeByBlockID[block.id].map {
                            Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
                        } ?? "None"
                    let isAnchored = alignmentStatusByBlockID[block.id] == "lockedAnchor"
                    paraCell.setManuallyAligned(isAnchored, timeString: timeString)
                    return paraCell
                }
            }
        }

        func applySnapshot(
            animated: Bool, in collectionView: UICollectionView, reconfiguring: [String] = []
        ) {
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            let sectionIDs = sections.map(\.id)
            snapshot.appendSections(sectionIDs)
            for section in sections {
                snapshot.appendItems(section.items.map(\.id), toSection: section.id)
            }
            let present = Set(sections.flatMap { $0.items.map(\.id) })
            let toReconfigure = reconfiguring.filter { present.contains($0) }
            if !toReconfigure.isEmpty { snapshot.reconfigureItems(toReconfigure) }
            dataSource?.apply(snapshot, animatingDifferences: animated)
            Task { @MainActor in
                self.updateTopChapterTitle(collectionView)
            }
        }

        func updateActiveBlock(_ blockID: String?, in collectionView: UICollectionView) {
            // Clear previous highlight on all visible cells
            for cell in collectionView.visibleCells {
                (cell as? HeadingCardCell)?.isActiveBlock = false
                (cell as? ParagraphCardCell)?.isActiveBlock = false
            }

            guard let blockID else { return }
            guard let dataSource = dataSource else { return }

            var targetIndexPath: IndexPath?

            // 1. Try finding it directly in the data source
            if let indexPath = dataSource.indexPath(for: "b-\(blockID)") {
                targetIndexPath = indexPath
            }

            guard let indexPath = targetIndexPath else { return }

            if let cell = collectionView.cellForItem(at: indexPath) {
                if let headingCell = cell as? HeadingCardCell {
                    headingCell.isActiveBlock = true
                } else if let paraCell = cell as? ParagraphCardCell {
                    paraCell.isActiveBlock = true
                }
            }

            if autoScrollEnabled.wrappedValue, lastScrolledBlockID != blockID {
                lastScrolledBlockID = blockID
                Task { @MainActor in
                    collectionView.scrollToItem(
                        at: indexPath, at: .centeredVertically, animated: true)
                }
            }
        }

        /// Retints the *visible* active cell to the spoken word without a diffable
        /// reload (reloading at word rate flickers). Newly-dequeued cells already
        /// get the right word via `cell(for:)`, so this only touches a cell that is
        /// already on screen. The block→IndexPath lookup reuses the same
        /// `dataSource.indexPath(for: "b-…")` map `updateActiveBlock` uses.
        func updateActiveWord(
            _ word: (blockID: String, index: Int)?, in collectionView: UICollectionView
        ) {
            let bodyFont = settings.uiFont(forTextStyle: .body, weight: .regular)
            let headingFont = settings.uiFont(forTextStyle: .title3, weight: .semibold)

            // Clear the previously-highlighted cell when the active word leaves its
            // block (or goes to nil) — otherwise that paragraph's last word lingers.
            if let clearID = KaraokeHighlightTransition.blockToClear(
                previous: lastHighlightedWordBlockID, next: word?.blockID),
                let ip = dataSource?.indexPath(for: "b-\(clearID)"),
                let prevCell = collectionView.cellForItem(at: ip)
            {
                (prevCell as? ParagraphCardCell)?.applyWordHighlight(nil, baseFont: bodyFont)
                (prevCell as? HeadingCardCell)?.applyWordHighlight(nil, baseFont: headingFont)
            }
            lastHighlightedWordBlockID = word?.blockID

            // Apply to the new active cell (if any, and if on screen).
            guard let word,
                let dataSource = dataSource,
                let indexPath = dataSource.indexPath(for: "b-\(word.blockID)"),
                let cell = collectionView.cellForItem(at: indexPath)
            else { return }
            // Fonts mirror those `cell(for:)` builds for each cell kind so the
            // highlighted word keeps the same metrics as the surrounding text.
            if let para = cell as? ParagraphCardCell {
                para.applyWordHighlight(word.index, baseFont: bodyFont)
            } else if let heading = cell as? HeadingCardCell {
                heading.applyWordHighlight(word.index, baseFont: headingFont)
            }
        }

        /// Triggers a brief scale-pulse animation on the cell for the given block ID.
        func pulseCell(for blockID: String, in collectionView: UICollectionView) {
            guard let dataSource = dataSource else { return }
            let indexPath = dataSource.indexPath(for: "b-\(blockID)")
            guard let indexPath, let cell = collectionView.cellForItem(at: indexPath) else {
                return
            }

            cell.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                usingSpringWithDamping: 0.5,
                initialSpringVelocity: 0.8,
                options: [.allowUserInteraction],
                animations: { cell.transform = .identity },
                completion: nil
            )

            // Brief background highlight flash
            let originalBg = cell.contentView.backgroundColor
            UIView.animate(
                withDuration: 0.15,
                animations: {
                    cell.contentView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.2)
                },
                completion: { _ in
                    UIView.animate(withDuration: 0.35) {
                        cell.contentView.backgroundColor = originalBg
                    }
                })
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if autoScrollEnabled.wrappedValue {
                autoScrollEnabled.wrappedValue = false
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateTopChapterTitle(scrollView)

            let offset = scrollView.contentOffset.y

            // If near top, always show header
            if offset <= 0 {
                if !isHeaderVisible.wrappedValue {
                    isHeaderVisible.wrappedValue = true
                }
                return
            }

            guard scrollView.isDragging else { return }

            let translation = scrollView.panGestureRecognizer.translation(in: scrollView.superview)
                .y

            if translation < -10 {
                // Scrolling down
                if isHeaderVisible.wrappedValue {
                    isHeaderVisible.wrappedValue = false
                }
            } else if translation > 10 {
                // Scrolling up
                if !isHeaderVisible.wrappedValue {
                    isHeaderVisible.wrappedValue = true
                }
            }
        }

        private func updateTopChapterTitle(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            let visibleRect = CGRect(
                origin: collectionView.contentOffset, size: collectionView.bounds.size)
            // Use the center of the visible area to determine the active header context
            let centerPoint = CGPoint(x: visibleRect.midX, y: visibleRect.midY)

            if let indexPath = collectionView.indexPathForItem(at: centerPoint) {
                updateChapterTitle(for: indexPath)
            } else if let topIndexPath = collectionView.indexPathsForVisibleItems.min() {
                updateChapterTitle(for: topIndexPath)
            }
        }

        private func updateChapterTitle(for indexPath: IndexPath) {
            if let sectionID = dataSource?.snapshot().sectionIdentifiers[indexPath.section],
                let section = sections.first(where: { $0.id == sectionID })
            {

                var partTitle: String? = nil
                var chapterTitle: String? = nil
                var sectionTitle: String? = nil

                let stack = section.headingStack.filter { !$0.isEmpty }
                var uniqueStack: [String] = []
                for item in stack {
                    if uniqueStack.last != item {
                        uniqueStack.append(item)
                    }
                }

                let count = uniqueStack.count
                // partTitle   = audio chapter title (always index 0)
                // chapterTitle = first EPUB heading that isn't the part title
                // sectionTitle = deepest heading that differs from both above
                if count >= 1 {
                    partTitle = uniqueStack[0]
                }
                if count >= 2 {
                    chapterTitle = uniqueStack[1]
                    if chapterTitle == partTitle, count >= 3 {
                        chapterTitle = uniqueStack[2]
                    }
                }
                if count >= 3 {
                    let candidate = uniqueStack.last!
                    if candidate != chapterTitle, candidate != partTitle {
                        sectionTitle = candidate
                    }
                }

                if topPartTitle.wrappedValue != partTitle {
                    Task { @MainActor in
                        self.topPartTitle.wrappedValue = partTitle
                    }
                }

                if topChapterTitle.wrappedValue != chapterTitle {
                    Task { @MainActor in
                        self.topChapterTitle.wrappedValue = chapterTitle
                    }
                }
                if topSectionTitle.wrappedValue != sectionTitle {
                    Task { @MainActor in
                        self.topSectionTitle.wrappedValue = sectionTitle
                    }
                }

                var resolvedTheme: String? = nil
                if let itemID = dataSource?.itemIdentifier(for: indexPath),
                    let item = card(for: itemID)
                {
                    switch item {
                    case .block(let block):
                        resolvedTheme = block.chapterThemeColor
                    case .chapterHeader(_, let chapterIndex):
                        resolvedTheme = chapterThemeColorByKey[chapterIndex]
                    case .bookmark, .ankiCard, .note, .voiceMemo:
                        break  // Tasks 7/8 will wire theme propagation for inline items.
                    }
                } else if let firstBlock = section.items.compactMap({ item -> EPubBlockRecord? in
                    if case .block(let b) = item { return b }
                    return nil
                }).first {
                    resolvedTheme = firstBlock.chapterThemeColor
                }
                if topChapterThemeColor.wrappedValue != resolvedTheme {
                    Task { @MainActor in
                        self.topChapterThemeColor.wrappedValue = resolvedTheme
                    }
                }
            }
        }

        func collectionView(
            _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
        ) {
            guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                let item = card(for: itemID)
            else { return }
            switch item {
            case .chapterHeader(_, let chapterIndex):
                onToggleChapter?(chapterIndex)
            case .block(let block):
                onTapBlock?(block.id)
            case .bookmark, .ankiCard, .note, .voiceMemo:
                break  // Tasks 7/8 will wire tap handlers for inline items.
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let indexPath = indexPaths.first,
                let itemID = dataSource?.itemIdentifier(for: indexPath),
                let item = card(for: itemID)
            else { return nil }
            switch item {
            case .chapterHeader(_, let chapterIndex):
                return onChapterHeaderContextMenu?(chapterIndex)
            case .block(let block):
                return onContextMenu?(block)
            default:
                return nil
            }
        }
    }
}

// MARK: - Bookmark cell

private final class BookmarkFeedCell: UICollectionViewCell {
    static let reuseIdentifier = "BookmarkFeedCell"

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let container = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 10
        container.layer.cornerCurve = .continuous
        contentView.addSubview(container)

        icon.image = UIImage(systemName: "bookmark.fill")
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        noteLabel.font = .preferredFont(forTextStyle: .subheadline)
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 3
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [titleLabel, noteLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with record: BookmarkRecord, tint: UIColor) {
        titleLabel.text = record.title
        noteLabel.text = record.note
        noteLabel.isHidden = (record.note ?? "").isEmpty
        icon.tintColor = tint
        container.backgroundColor = tint.withAlphaComponent(0.08)
        accessibilityLabel = [record.title, record.note].compactMap { $0 }.joined(separator: ": ")
    }
}

// MARK: - Anki card cell

private final class AnkiCardFeedCell: UICollectionViewCell {
    static let reuseIdentifier = "AnkiCardFeedCell"

    private let icon = UIImageView()
    private let frontLabel = UILabel()
    private let backLabel = UILabel()
    private let container = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 10
        container.layer.cornerCurve = .continuous
        contentView.addSubview(container)

        icon.image = UIImage(systemName: "rectangle.on.rectangle.angled")
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        frontLabel.font = .preferredFont(forTextStyle: .headline)
        frontLabel.numberOfLines = 3
        frontLabel.adjustsFontForContentSizeCategory = true
        frontLabel.translatesAutoresizingMaskIntoConstraints = false

        backLabel.font = .preferredFont(forTextStyle: .subheadline)
        backLabel.textColor = .secondaryLabel
        backLabel.numberOfLines = 4
        backLabel.adjustsFontForContentSizeCategory = true
        backLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [frontLabel, backLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with card: Flashcard, tint: UIColor) {
        frontLabel.text = card.frontText
        backLabel.text = card.backText
        backLabel.isHidden = card.backText.isEmpty
        icon.tintColor = tint
        container.backgroundColor = tint.withAlphaComponent(0.10)
        container.layer.borderWidth = 1
        container.layer.borderColor = tint.withAlphaComponent(0.25).cgColor
        accessibilityLabel = card.frontText
    }
}

// MARK: - Chapter Header Cell (collapsed-TOC row)

private final class ChapterDividerCell: UICollectionViewCell {
    static let reuseIdentifier = "ChapterDividerCell"

    private let chevron = UIImageView()
    private let titleLabel = UILabel()
    private let audioIcon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        chevron.contentMode = .scaleAspectFit
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true

        audioIcon.contentMode = .scaleAspectFit
        audioIcon.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [chevron, titleLabel, audioIcon])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 14),
            audioIcon.widthAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(
        title: String,
        hasAudio: Bool,
        isExpanded: Bool,
        offState: ChapterOffState = .allOn
    ) {
        titleLabel.text = title
        chevron.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
        if hasAudio {
            audioIcon.image = UIImage(systemName: "headphones")
            audioIcon.tintColor = .tintColor
            titleLabel.textColor = .label
        } else {
            audioIcon.image = UIImage(systemName: "text.alignleft")
            audioIcon.tintColor = .tertiaryLabel
            titleLabel.textColor = .secondaryLabel
        }
        // Phase 2: dim the whole row when anything is off.
        let dimmed = offState.isDimmed
        contentView.alpha = dimmed ? 0.45 : 1.0
        titleLabel.textColor = dimmed ? .secondaryLabel : titleLabel.textColor
        accessibilityLabel = title
        accessibilityValue =
            (hasAudio ? "Has audio" : "Text only") + ", " + (isExpanded ? "expanded" : "collapsed")
            + (dimmed ? ", off" : "")
    }
}
