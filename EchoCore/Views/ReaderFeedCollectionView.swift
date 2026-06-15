import SwiftUI
import UIKit

/// UIViewRepresentable wrapping a UICollectionView that renders the EPUB reader feed.
struct ReaderFeedCollectionView: UIViewRepresentable {
    var sections: [ReaderCardSection]
    @Binding var activeBlockID: String?
    @Binding var isHeaderVisible: Bool
    @Binding var autoScrollEnabled: Bool
    @Binding var topPartTitle: String?
    @Binding var topChapterTitle: String?
    @Binding var topSectionTitle: String?
    @Binding var topChapterThemeColor: String?
    let settings: ReaderSettings
    var alignmentStatusByBlockID: [String: String] = [:]
    var audioStartTimeByBlockID: [String: TimeInterval] = [:]
    var searchQuery: String? = nil
    var pulseBlockID: String? = nil
    var forceScrollBlockID: String? = nil
    var forceScrollTrigger: Int = 0
    var onTapBlock: ((String) -> Void)?
    var onContextMenu: ((EPubBlockRecord) -> UIContextMenuConfiguration?)?

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

        context.coordinator.dataSource = makeDataSource(for: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.onTapBlock = onTapBlock
        context.coordinator.onContextMenu = onContextMenu
        context.coordinator.settings = settings
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
            if let dataSource = context.coordinator.dataSource,
                let indexPath = dataSource.indexPath(for: "b-\(forceID)")
            {
                Task { @MainActor in
                    collectionView.scrollToItem(
                        at: indexPath, at: .centeredVertically, animated: true)
                }
            }
        }

        if sections != context.coordinator.sections {
            let wasEmpty = context.coordinator.sections.isEmpty
            context.coordinator.sections = sections
            context.coordinator.applySnapshot(animated: !wasEmpty, in: collectionView)

            if wasEmpty, let firstSection = sections.first,
                let title = firstSection.headingStack.first
            {
                Task { @MainActor in
                    self.topChapterTitle = title
                }
            }
        }

        context.coordinator.updateActiveBlock(activeBlockID, in: collectionView)
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
        var searchQuery: String? = nil
        var pulseBlockID: String? = nil
        var dataSource: UICollectionViewDiffableDataSource<String, String>?
        var sections: [ReaderCardSection] = []
        var activeBlockID: String?
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
            case .chapterHeader(let title, _):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: ChapterDividerCell.reuseIdentifier, for: indexPath
                    ) as? ChapterDividerCell
                else { return UICollectionViewCell() }
                cell.configure(with: title)
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
                    headingCell.configure(
                        with: block, font: font, tint: cardTint,
                        isExplicitHighlight: block.cardColor != nil
                            || block.chapterThemeColor != nil, searchQuery: searchQuery)
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
                    paraCell.configure(
                        with: block, font: font, tint: cardTint, lineSpacing: settings.lineSpacing,
                        isExplicitHighlight: block.cardColor != nil
                            || block.chapterThemeColor != nil, searchQuery: searchQuery)
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

        func applySnapshot(animated: Bool, in collectionView: UICollectionView) {
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            let sectionIDs = sections.map(\.id)
            snapshot.appendSections(sectionIDs)
            for section in sections {
                snapshot.appendItems(section.items.map(\.id), toSection: section.id)
            }
            dataSource?.apply(snapshot, animatingDifferences: animated)
            DispatchQueue.main.async {
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
                DispatchQueue.main.async {
                    collectionView.scrollToItem(
                        at: indexPath, at: .centeredVertically, animated: true)
                }
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
                    DispatchQueue.main.async {
                        self.topPartTitle.wrappedValue = partTitle
                    }
                }

                if topChapterTitle.wrappedValue != chapterTitle {
                    DispatchQueue.main.async {
                        self.topChapterTitle.wrappedValue = chapterTitle
                    }
                }
                if topSectionTitle.wrappedValue != sectionTitle {
                    DispatchQueue.main.async {
                        self.topSectionTitle.wrappedValue = sectionTitle
                    }
                }

                if let itemID = dataSource?.itemIdentifier(for: indexPath),
                    case .block(let block) = card(for: itemID)
                {
                    let themeColor = block.chapterThemeColor
                    if topChapterThemeColor.wrappedValue != themeColor {
                        DispatchQueue.main.async {
                            self.topChapterThemeColor.wrappedValue = themeColor
                        }
                    }
                } else if let firstBlock = section.items.compactMap({ item -> EPubBlockRecord? in
                    if case .block(let b) = item { return b }
                    return nil
                }).first {
                    let themeColor = firstBlock.chapterThemeColor
                    if topChapterThemeColor.wrappedValue != themeColor {
                        DispatchQueue.main.async {
                            self.topChapterThemeColor.wrappedValue = themeColor
                        }
                    }
                }
            }
        }

        func collectionView(
            _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
        ) {
            guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                case .block(let block) = card(for: itemID)
            else { return }
            onTapBlock?(block.id)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let indexPath = indexPaths.first,
                let itemID = dataSource?.itemIdentifier(for: indexPath),
                case .block(let block) = card(for: itemID)
            else { return nil }
            return onContextMenu?(block)
        }
    }
}

// MARK: - Chapter Divider Cell

private final class ChapterDividerCell: UICollectionViewCell {
    static let reuseIdentifier = "ChapterDividerCell"

    private let label: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with title: String) {
        label.text = "— \(title) —"
    }
}
