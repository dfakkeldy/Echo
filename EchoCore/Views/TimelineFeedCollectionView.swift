import SwiftUI
import UIKit
import os.log

// MARK: - SwiftUI Wrapper

struct TimelineFeedCollectionView: UIViewRepresentable {
    @Binding var items: [TimelineDisplayItem]
    @Binding var currentPosition: TimeInterval
    @Binding var scrollTargetPosition: TimeInterval?
    var isFollowingPlayback: Bool
    var onUserScrolled: () -> Void
    var bottomInset: CGFloat

    /// Called when the user taps a feed item.
    var onItemTapped: ((TimelineDisplayItem) -> Void)?
    /// Called on long-press / context-menu to edit the item.
    var onContextMenuAction: ((TimelineDisplayItem) -> Void)?
    /// Called when the user requests deletion of a bookmark via context menu.
    var onDeleteBookmark: ((TimelineItem) -> Void)?
    /// Called for EPUB block context actions: play from here, move to now, hide, unhide.
    var onEPUBBlockAction: ((TimelineItem, EPUBBlockAction) -> Void)?

    enum EPUBBlockAction {
        case playFromHere
        case moveToNow
        case searchSimilar
        case hide
        case unhide
        case eraseAnchor
        case resetAlignment
    }

    /// The first due Anki card currently visible in the feed, for sticky header display.
    var dueAnkiCard: TimelineItem? = nil
    /// Called when the user grades or dismisses the sticky review.
    var onGradeDueCard: ((Int) -> Void)?
    var onDismissDueCard: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = makeLayout()
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = context.coordinator
        collectionView.showsVerticalScrollIndicator = true
        collectionView.alwaysBounceVertical = true

        collectionView.register(
            TextSegmentCell.self,
            forCellWithReuseIdentifier: TextSegmentCell.reuseID
        )
        collectionView.register(
            ChapterMarkerCell.self,
            forCellWithReuseIdentifier: ChapterMarkerCell.reuseID
        )
        collectionView.register(
            ImageAssetCell.self,
            forCellWithReuseIdentifier: ImageAssetCell.reuseID
        )
        collectionView.register(
            BookmarkCell.self,
            forCellWithReuseIdentifier: BookmarkCell.reuseID
        )
        collectionView.register(
            AnkiCardCell.self,
            forCellWithReuseIdentifier: AnkiCardCell.reuseID
        )
        collectionView.register(
            ElasticScrubberCell.self,
            forCellWithReuseIdentifier: ElasticScrubberCell.reuseID
        )
        collectionView.register(
            NowLineCell.self,
            forCellWithReuseIdentifier: NowLineCell.reuseID
        )
        collectionView.register(
            BookCardCell.self,
            forCellWithReuseIdentifier: BookCardCell.reuseID
        )
        collectionView.register(
            StickyReviewHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: StickyReviewHeaderView.reuseID
        )

        context.coordinator.collectionView = collectionView
        context.coordinator.parent = self

        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)

        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let displayIDs = items.map { $0.id }

        // Update bottom inset dynamically if it changes
        let targetInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        if collectionView.contentInset != targetInsets {
            collectionView.contentInset = targetInsets
            collectionView.verticalScrollIndicatorInsets = targetInsets
        }

        // Only rebuild the diffable snapshot when items actually change.
        if displayIDs != context.coordinator.currentItems {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            let section = 0
            snapshot.appendSections([section])
            snapshot.appendItems(displayIDs, toSection: section)

            var itemLookup: [String: TimelineDisplayItem] = [:]
            for item in items { itemLookup[item.id] = item }
            context.coordinator.itemLookup = itemLookup
            context.coordinator.currentItems = displayIDs

            context.coordinator.dataSource.apply(snapshot, animatingDifferences: false)
        }

        context.coordinator.currentPosition = currentPosition

        // Detect scroll target changes and animate to position.
        if let target = scrollTargetPosition, target != context.coordinator.lastScrollTarget {
            context.coordinator.lastScrollTarget = target
            context.coordinator.scrollTo(position: target, animated: true)
        }
    }

    static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
        coordinator.collectionView = nil
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(60)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(60)
            )
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)

            // Sticky review header — pinned to top while due Anki card is visible
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(72)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]

            return section
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate {
        weak var collectionView: UICollectionView?
        var parent: TimelineFeedCollectionView?
        var currentItems: [String] = []
        var itemLookup: [String: TimelineDisplayItem] = [:]
        var currentPosition: TimeInterval = 0
        var lastScrollTarget: TimeInterval?
        private var isProgrammaticScroll = false

        // MARK: - Smooth scroll (Core Animation — offloaded to render server)

        /// Animates the collection view's content offset using `UIView.animate`,
        /// which hands the interpolation to Core Animation on the render server.
        /// This avoids the 60 fps main-thread wake-ups of a `CADisplayLink`.
        private func animateScrollTo(targetOffset: CGFloat) {
            guard let cv = collectionView else { return }
            let maxOffset = max(0, cv.contentSize.height - cv.bounds.height)
            let clamped = min(max(0, targetOffset), maxOffset)

            isProgrammaticScroll = true
            UIView.animate(
                withDuration: 0.35,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: {
                    cv.contentOffset = CGPoint(x: 0, y: clamped)
                },
                completion: { [weak self] _ in
                    self?.isProgrammaticScroll = false
                }
            )
        }

        // MARK: - Data Source

        lazy var dataSource: UICollectionViewDiffableDataSource<Int, String> = {
            guard let cv = collectionView else {
                preconditionFailure("CollectionView not available for data source setup")
            }
            let ds = UICollectionViewDiffableDataSource<Int, String>(
                collectionView: cv
            ) { [weak self] collectionView, indexPath, identifier in
                self?.cellProvider(collectionView, indexPath: indexPath, identifier: identifier)
            }
            ds.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                self?.supplementaryProvider(collectionView, kind: kind, indexPath: indexPath)
            }
            return ds
        }()

        private func cellProvider(
            _ collectionView: UICollectionView,
            indexPath: IndexPath,
            identifier: String
        ) -> UICollectionViewCell {
            guard let displayItem = itemLookup[identifier] else {
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: TextSegmentCell.reuseID, for: indexPath
                )
            }

            switch displayItem {
            case .nowLine:
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: NowLineCell.reuseID, for: indexPath
                )

            case .scrubberGap(let duration, _):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ElasticScrubberCell.reuseID, for: indexPath
                )
                guard let cell = cell as? ElasticScrubberCell else {
                    os_log(.error, "Expected ElasticScrubberCell, got %{public}@", String(describing: type(of: cell)))
                    return cell
                }
                cell.configure(gapDuration: duration)
                return cell

            case .audiobookCard(let info):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: BookCardCell.reuseID, for: indexPath
                )
                guard let cell = cell as? BookCardCell else {
                    os_log(.error, "Expected BookCardCell, got %{public}@", String(describing: type(of: cell)))
                    return cell
                }
                cell.configure(info)
                return cell

            case .timelineItem(let item):
                return configureTimelineItemCell(item, collectionView: collectionView, indexPath: indexPath)
            }
        }

        private func configureTimelineItemCell(
            _ item: TimelineItem,
            collectionView: UICollectionView,
            indexPath: IndexPath
        ) -> UICollectionViewCell {
            let reuseID: String
            switch item.itemType {
            case .textSegment: reuseID = TextSegmentCell.reuseID
            case .chapterMarker: reuseID = ChapterMarkerCell.reuseID
            case .imageAsset: reuseID = ImageAssetCell.reuseID
            case .bookmark: reuseID = BookmarkCell.reuseID
            case .ankiCard: reuseID = AnkiCardCell.reuseID
            }

            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: reuseID, for: indexPath
            )
            configure(cell: cell, with: item)
            return cell
        }

        private func supplementaryProvider(
            _ collectionView: UICollectionView,
            kind: String,
            indexPath: IndexPath
        ) -> UICollectionReusableView {
            guard kind == UICollectionView.elementKindSectionHeader else {
                return UICollectionReusableView()
            }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: StickyReviewHeaderView.reuseID,
                for: indexPath
            )
            guard let header = header as? StickyReviewHeaderView else {
                os_log(.error, "Expected StickyReviewHeaderView, got %{public}@", String(describing: type(of: header)))
                return header
            }
            if let card = parent?.dueAnkiCard {
                header.configure(
                    frontText: card.title,
                    backText: card.subtitle,
                    onGrade: { [weak self] grade in self?.parent?.onGradeDueCard?(grade) },
                    onDismiss: { [weak self] in self?.parent?.onDismissDueCard?() }
                )
                header.isHidden = false
            } else {
                header.isHidden = true
            }
            return header
        }

        private func configure(cell: UICollectionViewCell, with item: TimelineItem) {
            let isHistory = item.effectivePosition < currentPosition
            switch cell {
            case let c as TextSegmentCell:
                c.delegate = self
                c.configure(item, isHistory: isHistory)
            case let c as ChapterMarkerCell:
                c.delegate = self
                c.configure(item, isHistory: isHistory)
            case let c as ImageAssetCell:
                c.delegate = self
                c.configure(item, isHistory: isHistory)
            case let c as BookmarkCell:
                c.delegate = self
                c.configure(item, isHistory: isHistory)
            case let c as AnkiCardCell:
                c.delegate = self
                c.configure(item, isHistory: isHistory)
            default:
                break
            }
        }

        // MARK: - Scroll Detection

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll else { return }
            parent?.onUserScrolled()
        }

        // MARK: - Item Selection (Tap)

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let identifier = currentItems[safe: indexPath.item],
                  let displayItem = itemLookup[identifier],
                  !isNowLineOrGap(displayItem)
            else { return }
            parent?.onItemTapped?(displayItem)
        }

        // MARK: - Context Menu (Long Press)

        func collectionView(_ collectionView: UICollectionView,
                            contextMenuConfigurationForItemAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard let identifier = currentItems[safe: indexPath.item],
                  let displayItem = itemLookup[identifier],
                  !isNowLineOrGap(displayItem)
            else { return nil }

            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                var children: [UIAction] = []
                let parent = self?.parent

                if case .timelineItem(let item) = displayItem {
                    // EPUB block actions (text segments and image assets from EPUB)
                    if item.sourceTable == "epub_block" || item.epubBlockID != nil {
                        if item.isTimestamped {
                            children.append(UIAction(
                                title: "Play From Here",
                                image: UIImage(systemName: "play.fill")
                            ) { _ in
                                parent?.onEPUBBlockAction?(item, .playFromHere)
                            })
                        }

                        children.append(UIAction(
                            title: "Move to Now",
                            image: UIImage(systemName: "clock.arrow.circlepath")
                        ) { _ in
                            parent?.onEPUBBlockAction?(item, .moveToNow)
                        })

                        children.append(UIAction(
                            title: "Search Similar Text",
                            image: UIImage(systemName: "magnifyingglass")
                        ) { _ in
                            parent?.onEPUBBlockAction?(item, .searchSimilar)
                        })

                        if item.isEnabled {
                            children.append(UIAction(
                                title: "Hide Omitted Text",
                                image: UIImage(systemName: "eye.slash")
                            ) { _ in
                                parent?.onEPUBBlockAction?(item, .hide)
                            })
                        } else {
                            children.append(UIAction(
                                title: "Unhide",
                                image: UIImage(systemName: "eye")
                            ) { _ in
                                parent?.onEPUBBlockAction?(item, .unhide)
                            })
                        }

                        if item.alignmentStatus == "lockedAnchor" {
                            children.append(UIAction(
                                title: "Erase Anchor",
                                image: UIImage(systemName: "link.badge.minus"),
                                attributes: .destructive
                            ) { _ in
                                parent?.onEPUBBlockAction?(item, .eraseAnchor)
                            })
                        }

                        children.append(UIAction(
                            title: "Reset Alignment",
                            image: UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath"),
                            attributes: .destructive
                        ) { _ in
                            parent?.onEPUBBlockAction?(item, .resetAlignment)
                        })
                    }

                    // Bookmark actions
                    if item.itemType == .bookmark {
                        if children.isEmpty {
                            let edit = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                                parent?.onContextMenuAction?(displayItem)
                            }
                            children.append(edit)
                        }
                        let delete = UIAction(
                            title: "Delete", image: UIImage(systemName: "trash"),
                            attributes: .destructive
                        ) { _ in
                            parent?.onDeleteBookmark?(item)
                        }
                        children.append(delete)
                    }

                    // Chapter marker actions: fall through to default edit
                    if item.itemType == .chapterMarker, children.isEmpty {
                        let edit = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                            parent?.onContextMenuAction?(displayItem)
                        }
                        children.append(edit)
                    }

                    // Default: generic edit for non-EPUB, non-bookmark items
                    if children.isEmpty {
                        let edit = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                            parent?.onContextMenuAction?(displayItem)
                        }
                        children.append(edit)
                    }
                } else if case .audiobookCard = displayItem {
                    // Book card: no context menu actions currently
                    let info = UIAction(title: "Play Book", image: UIImage(systemName: "play.fill")) { _ in
                        parent?.onItemTapped?(displayItem)
                    }
                    children.append(info)
                }

                let title: String
                switch displayItem {
                case .audiobookCard(let info): title = info.title
                case .timelineItem(let item): title = item.title
                default: title = ""
                }

                return UIMenu(title: title, children: children)
            }
        }

        private func isNowLineOrGap(_ item: TimelineDisplayItem) -> Bool {
            switch item {
            case .nowLine, .scrubberGap: return true
            default: return false
            }
        }

        // MARK: - Active Item Highlighting

        func updateActiveHighlight(position: TimeInterval) {
            guard let cv = collectionView else { return }
            for (index, identifier) in currentItems.enumerated() {
                guard let displayItem = itemLookup[identifier],
                      case .timelineItem(let item) = displayItem
                else { continue }

                let isActive = position >= item.audioStartTime
                    && (item.audioEndTime.map { position < $0 } ?? true)
                if isActive, let cell = cv.cellForItem(at: IndexPath(item: index, section: 0)) as? TextSegmentCell {
                    cell.setActive(true)
                } else if let cell = cv.cellForItem(at: IndexPath(item: index, section: 0)) as? TextSegmentCell {
                    cell.setActive(false)
                }
            }
        }

        // MARK: - Programmatic Scroll

        func scrollTo(itemID: String, animated: Bool = true) {
            guard let cv = collectionView else { return }
            for (index, identifier) in currentItems.enumerated() {
                if identifier == itemID {
                    isProgrammaticScroll = true
                    let indexPath = IndexPath(item: index, section: 0)
                    cv.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.isProgrammaticScroll = false
                    }
                    return
                }
            }
        }

        /// Smooth scroll to center the NowLine in the viewport. Animated scroll
        /// is offloaded to Core Animation via `UIView.animate` (render-server
        /// interpolation instead of 60 fps main-thread CADisplayLink wake-ups).
        func scrollToNowLine(animated: Bool = true) {
            guard let cv = collectionView else { return }

            // Find the NowLine index
            guard let nowLineIndex = currentItems.firstIndex(where: { id in
                if case .nowLine = itemLookup[id] { return true }
                return false
            }) else { return }

            let indexPath = IndexPath(item: nowLineIndex, section: 0)

            // Get the layout attributes for the NowLine cell
            guard let attrs = cv.collectionViewLayout.layoutAttributesForItem(at: indexPath) else {
                // Fallback: use scrollToItem which is also render-server offloaded
                isProgrammaticScroll = true
                cv.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.isProgrammaticScroll = false
                }
                return
            }

            let cellCenter = attrs.frame.midY
            let targetOffset = cellCenter - (cv.bounds.height / 2)

            if animated {
                animateScrollTo(targetOffset: targetOffset)
            } else {
                cv.setContentOffset(CGPoint(x: 0, y: max(0, targetOffset)), animated: false)
            }
        }

        /// Scroll to center the item closest to the given time position, using smooth interpolation.
        func scrollTo(position: TimeInterval, animated: Bool = true) {
            scrollToNowLine(animated: animated)
        }
    }
}

// MARK: - Coordinator: TimelineCellDelegate

extension TimelineFeedCollectionView.Coordinator: TimelineCellDelegate {
    func timelineCellDidTapPlay(_ cell: UICollectionViewCell, item: TimelineItem) {
        parent?.onEPUBBlockAction?(item, .playFromHere)
    }

    func timelineCellDidTapPin(_ cell: UICollectionViewCell, item: TimelineItem) {
        parent?.onEPUBBlockAction?(item, .moveToNow)
    }

    func timelineCellDidTapSearch(_ cell: UICollectionViewCell, item: TimelineItem) {
        parent?.onEPUBBlockAction?(item, .searchSimilar)
    }

    func timelineCellDidTapHideToggle(_ cell: UICollectionViewCell, item: TimelineItem) {
        if item.isEnabled {
            parent?.onEPUBBlockAction?(item, .hide)
        } else {
            parent?.onEPUBBlockAction?(item, .unhide)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
