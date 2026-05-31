import SwiftUI
import UIKit
import os.log

// MARK: - Timeline Cell Delegate

protocol TimelineCellDelegate: AnyObject {
    func timelineCellDidTapPlay(_ cell: UICollectionViewCell, item: TimelineItem)
    func timelineCellDidTapPin(_ cell: UICollectionViewCell, item: TimelineItem)
    func timelineCellDidTapSearch(_ cell: UICollectionViewCell, item: TimelineItem)
    func timelineCellDidTapHideToggle(_ cell: UICollectionViewCell, item: TimelineItem)
}

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
        coordinator.stopDisplayLink()
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

        // MARK: - DisplayLink for smooth scrolling

        private var displayLink: CADisplayLink?
        private var scrollTarget: CGFloat?
        private var displayLinkContinuations: Int = 0
        private let maxDisplayLinkFrames: Int = 300 // ~5 seconds at 60fps

        func startDisplayLink(targetOffset: CGFloat) {
            scrollTarget = targetOffset
            displayLinkContinuations = 0
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
            displayLink?.add(to: .main, forMode: .default)
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            scrollTarget = nil
        }

        @objc private func displayLinkFired() {
            guard let cv = collectionView,
                  let target = scrollTarget,
                  displayLinkContinuations < maxDisplayLinkFrames
            else {
                stopDisplayLink()
                return
            }

            displayLinkContinuations += 1
            let currentOffset = cv.contentOffset.y
            let maxOffset = max(0, cv.contentSize.height - cv.bounds.height)

            // Ease-in interpolation: each frame moves 15% closer to target
            let newOffset = currentOffset + (target - currentOffset) * 0.15
            let clamped = min(max(0, newOffset), maxOffset)

            cv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)

            // Stop when close enough to target (within 0.5pt)
            if abs(clamped - target) < 0.5 {
                stopDisplayLink()
            }
        }

        // MARK: - Data Source

        lazy var dataSource: UICollectionViewDiffableDataSource<Int, String> = {
            guard let cv = collectionView else {
                fatalError("CollectionView not available for data source setup")
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
            stopDisplayLink()
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
                var children: [UIMenuElement] = []
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

        /// Smooth scroll to center the NowLine in the viewport using CADisplayLink interpolation.
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
                // Fallback: use scrollToItem
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
                isProgrammaticScroll = true
                startDisplayLink(targetOffset: targetOffset)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.isProgrammaticScroll = false
                }
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

// MARK: - Base Twitter-Feed Card Styling

private extension UICollectionViewCell {
    func applyCardStyle() {
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.borderWidth = 1.0 / max(1, contentView.traitCollection.displayScale)
        contentView.layer.borderColor = UIColor.separator.cgColor
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.06
        contentView.layer.shadowRadius = 3
        contentView.layer.shadowOffset = CGSize(width: 0, height: 1)
        contentView.layer.masksToBounds = false
        layer.masksToBounds = false
    }
}

// MARK: - BookCardCell

final class BookCardCell: UICollectionViewCell {
    static let reuseID = "BookCardCell"

    private let coverPlaceholder = UIView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let durationLabel = UILabel()
    private let playingIndicator = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .systemIndigo.withAlphaComponent(0.08)
        contentView.layer.cornerRadius = 12

        coverPlaceholder.backgroundColor = .systemIndigo.withAlphaComponent(0.15)
        coverPlaceholder.layer.cornerRadius = 8
        coverPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: "book.fill"))
        iconView.tintColor = .systemIndigo
        iconView.translatesAutoresizingMaskIntoConstraints = false
        coverPlaceholder.addSubview(iconView)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        authorLabel.font = .preferredFont(forTextStyle: .subheadline)
        authorLabel.textColor = .secondaryLabel
        authorLabel.numberOfLines = 1
        authorLabel.translatesAutoresizingMaskIntoConstraints = false

        durationLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        durationLabel.textColor = .tertiaryLabel
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        playingIndicator.image = UIImage(systemName: "play.circle.fill")
        playingIndicator.tintColor = .systemIndigo
        playingIndicator.translatesAutoresizingMaskIntoConstraints = false
        playingIndicator.isHidden = true

        contentView.addSubview(coverPlaceholder)
        contentView.addSubview(titleLabel)
        contentView.addSubview(authorLabel)
        contentView.addSubview(durationLabel)
        contentView.addSubview(playingIndicator)

        NSLayoutConstraint.activate([
            coverPlaceholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            coverPlaceholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            coverPlaceholder.widthAnchor.constraint(equalToConstant: 48),
            coverPlaceholder.heightAnchor.constraint(equalToConstant: 48),

            iconView.centerXAnchor.constraint(equalTo: coverPlaceholder.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: coverPlaceholder.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: coverPlaceholder.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: playingIndicator.leadingAnchor, constant: -8),

            authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            authorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            durationLabel.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 4),
            durationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            playingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playingIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            playingIndicator.widthAnchor.constraint(equalToConstant: 24),
            playingIndicator.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func configure(_ info: AudiobookCardInfo) {
        titleLabel.text = info.title
        authorLabel.text = info.author ?? ""
        authorLabel.isHidden = info.author == nil
        durationLabel.text = formatDuration(info.duration)
        playingIndicator.isHidden = !info.isCurrentlyPlaying
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 {
            return "\(h)h \(String(format: "%02d", m))m"
        }
        return "\(m)m"
    }
}

// MARK: - Action Footer Builder

private func makeActionButton(systemName: String, action: @escaping () -> Void) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: systemName,
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    // Larger hit target while keeping 14pt icon size.
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    config.baseForegroundColor = .secondaryLabel
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
}

// MARK: - TextSegmentCell (Twitter-feed card)

final class TextSegmentCell: UICollectionViewCell {
    static let reuseID = "TextSegmentCell"

    weak var delegate: TimelineCellDelegate?
    private var item: TimelineItem?

    private let avatarView = UIImageView()
    private let handleLabel = UILabel()
    private let dotLabel = UILabel()
    private let timestampLabel = UILabel()
    private let anchorIcon = UIImageView()
    private let bodyLabel = UILabel()
    private let headerStack = UIStackView()
    private let rightStack = UIStackView()
    private let actionStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        delegate = nil
        item = nil
    }

    private func setup() {
        applyCardStyle()

        avatarView.image = UIImage(systemName: "text.alignleft")
        avatarView.tintColor = .systemBlue
        avatarView.contentMode = .center
        avatarView.backgroundColor = .systemBlue.withAlphaComponent(0.12)
        avatarView.layer.cornerRadius = 18
        avatarView.clipsToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        handleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        handleLabel.textColor = .label
        handleLabel.text = "@epub_reader"

        dotLabel.text = "•"
        dotLabel.font = .preferredFont(forTextStyle: .caption1)
        dotLabel.textColor = .tertiaryLabel

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .secondaryLabel
        
        anchorIcon.image = UIImage(systemName: "link.circle")
        anchorIcon.tintColor = .systemGreen
        anchorIcon.translatesAutoresizingMaskIntoConstraints = false
        anchorIcon.isHidden = true
        anchorIcon.contentMode = .scaleAspectFit

        headerStack.axis = .horizontal
        headerStack.spacing = 4
        headerStack.alignment = .firstBaseline
        headerStack.addArrangedSubview(handleLabel)
        headerStack.addArrangedSubview(dotLabel)
        headerStack.addArrangedSubview(timestampLabel)
        headerStack.addArrangedSubview(anchorIcon)
        headerStack.setCustomSpacing(4, after: timestampLabel)

        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = .label
        bodyLabel.numberOfLines = 0

        actionStack.axis = .horizontal
        actionStack.spacing = 2
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        rightStack.axis = .vertical
        rightStack.spacing = 4
        rightStack.alignment = .leading
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(headerStack)
        rightStack.addArrangedSubview(bodyLabel)
        rightStack.addArrangedSubview(actionStack)

        contentView.addSubview(avatarView)
        contentView.addSubview(rightStack)

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            rightStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        self.item = item
        bodyLabel.text = item.textPayload ?? item.title
        timestampLabel.text = formatHMS(item.audioStartTime)
        anchorIcon.isHidden = item.alignmentStatus != "lockedAnchor"
        contentView.alpha = isHistory ? 0.65 : 1.0

        rebuildActions(for: item)
    }

    func setActive(_ active: Bool) {
        // Active state reflected via background tint shift.
        contentView.backgroundColor = active
            ? UIColor.systemBlue.withAlphaComponent(0.08)
            : .secondarySystemGroupedBackground
    }

    private func rebuildActions(for item: TimelineItem) {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let playBtn = makeActionButton(systemName: "play.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPlay(self, item: item)
        }
        let pinBtn = makeActionButton(systemName: "pin.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPin(self, item: item)
        }
        let searchBtn = makeActionButton(systemName: "magnifyingglass") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapSearch(self, item: item)
        }
        let eyeIcon = item.isEnabled ? "eye.slash" : "eye"
        let hideBtn = makeActionButton(systemName: eyeIcon) { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapHideToggle(self, item: item)
        }

        actionStack.addArrangedSubview(playBtn)
        actionStack.addArrangedSubview(pinBtn)
        actionStack.addArrangedSubview(searchBtn)
        actionStack.addArrangedSubview(hideBtn)
    }

    private func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - ChapterMarkerCell (Twitter-feed card)

final class ChapterMarkerCell: UICollectionViewCell {
    static let reuseID = "ChapterMarkerCell"

    weak var delegate: TimelineCellDelegate?
    private var item: TimelineItem?

    private let avatarView = UIImageView()
    private let handleLabel = UILabel()
    private let dotLabel = UILabel()
    private let timestampLabel = UILabel()
    private let anchorIcon = UIImageView()
    private let titleLabel = UILabel()
    private let durationLabel = UILabel()
    private let headerStack = UIStackView()
    private let rightStack = UIStackView()
    private let actionStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        delegate = nil
        item = nil
    }

    private func setup() {
        applyCardStyle()

        avatarView.image = UIImage(systemName: "number.circle.fill")
        avatarView.tintColor = .systemGray
        avatarView.contentMode = .center
        avatarView.backgroundColor = .systemGray.withAlphaComponent(0.12)
        avatarView.layer.cornerRadius = 18
        avatarView.clipsToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        handleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        handleLabel.textColor = .label
        handleLabel.text = "@chapter_store"

        dotLabel.text = "•"
        dotLabel.font = .preferredFont(forTextStyle: .caption1)
        dotLabel.textColor = .tertiaryLabel

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .secondaryLabel

        anchorIcon.image = UIImage(systemName: "link.circle")
        anchorIcon.tintColor = .systemGreen
        anchorIcon.translatesAutoresizingMaskIntoConstraints = false
        anchorIcon.isHidden = true
        anchorIcon.contentMode = .scaleAspectFit

        headerStack.axis = .horizontal
        headerStack.spacing = 4
        headerStack.alignment = .firstBaseline
        headerStack.addArrangedSubview(handleLabel)
        headerStack.addArrangedSubview(dotLabel)
        headerStack.addArrangedSubview(timestampLabel)
        headerStack.addArrangedSubview(anchorIcon)
        headerStack.setCustomSpacing(4, after: timestampLabel)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        durationLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        durationLabel.textColor = .secondaryLabel

        actionStack.axis = .horizontal
        actionStack.spacing = 2
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        rightStack.axis = .vertical
        rightStack.spacing = 4
        rightStack.alignment = .leading
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(headerStack)
        rightStack.addArrangedSubview(titleLabel)
        rightStack.addArrangedSubview(durationLabel)
        rightStack.addArrangedSubview(actionStack)

        contentView.addSubview(avatarView)
        contentView.addSubview(rightStack)

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            rightStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        self.item = item
        titleLabel.text = item.title
        if let subtitle = item.subtitle {
            durationLabel.text = subtitle
        } else {
            durationLabel.text = formatHMS(item.audioStartTime)
        }
        durationLabel.isHidden = false
        timestampLabel.text = formatHMS(item.audioStartTime)
        anchorIcon.isHidden = item.alignmentStatus != "lockedAnchor"
        contentView.alpha = isHistory ? 0.65 : 1.0

        rebuildActions(for: item)
    }

    private func rebuildActions(for item: TimelineItem) {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let playBtn = makeActionButton(systemName: "play.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPlay(self, item: item)
        }
        let pinBtn = makeActionButton(systemName: "pin.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPin(self, item: item)
        }
        let searchBtn = makeActionButton(systemName: "magnifyingglass") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapSearch(self, item: item)
        }
        let eyeIcon = item.isEnabled ? "eye.slash" : "eye"
        let hideBtn = makeActionButton(systemName: eyeIcon) { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapHideToggle(self, item: item)
        }

        actionStack.addArrangedSubview(playBtn)
        actionStack.addArrangedSubview(pinBtn)
        actionStack.addArrangedSubview(searchBtn)
        actionStack.addArrangedSubview(hideBtn)
    }

    private func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - BookmarkCell (Twitter-feed card)

final class BookmarkCell: UICollectionViewCell {
    static let reuseID = "BookmarkCell"

    weak var delegate: TimelineCellDelegate?
    private var item: TimelineItem?

    private let avatarView = UIImageView()
    private let handleLabel = UILabel()
    private let dotLabel = UILabel()
    private let timestampLabel = UILabel()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let headerStack = UIStackView()
    private let rightStack = UIStackView()
    private let actionStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        delegate = nil
        item = nil
    }

    private func setup() {
        applyCardStyle()

        avatarView.image = UIImage(systemName: "bookmark.fill")
        avatarView.tintColor = .systemOrange
        avatarView.contentMode = .center
        avatarView.backgroundColor = .systemOrange.withAlphaComponent(0.12)
        avatarView.layer.cornerRadius = 18
        avatarView.clipsToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        handleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        handleLabel.textColor = .label
        handleLabel.text = "@bookmark_store"

        dotLabel.text = "•"
        dotLabel.font = .preferredFont(forTextStyle: .caption1)
        dotLabel.textColor = .tertiaryLabel

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .secondaryLabel

        headerStack.axis = .horizontal
        headerStack.spacing = 4
        headerStack.alignment = .firstBaseline
        headerStack.addArrangedSubview(handleLabel)
        headerStack.addArrangedSubview(dotLabel)
        headerStack.addArrangedSubview(timestampLabel)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        noteLabel.font = .preferredFont(forTextStyle: .caption1)
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 2

        actionStack.axis = .horizontal
        actionStack.spacing = 2
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        rightStack.axis = .vertical
        rightStack.spacing = 4
        rightStack.alignment = .leading
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(headerStack)
        rightStack.addArrangedSubview(titleLabel)
        rightStack.addArrangedSubview(noteLabel)
        rightStack.addArrangedSubview(actionStack)

        contentView.addSubview(avatarView)
        contentView.addSubview(rightStack)

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            rightStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        self.item = item
        titleLabel.text = item.title
        noteLabel.text = item.subtitle
        noteLabel.isHidden = item.subtitle?.isEmpty ?? true
        timestampLabel.text = formatHMS(item.audioStartTime)
        contentView.alpha = isHistory ? 0.65 : 1.0

        rebuildActions(for: item)
    }

    private func rebuildActions(for item: TimelineItem) {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let playBtn = makeActionButton(systemName: "play.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPlay(self, item: item)
        }
        let pinBtn = makeActionButton(systemName: "pin.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPin(self, item: item)
        }
        let searchBtn = makeActionButton(systemName: "magnifyingglass") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapSearch(self, item: item)
        }
        let eyeIcon = item.isEnabled ? "eye.slash" : "eye"
        let hideBtn = makeActionButton(systemName: eyeIcon) { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapHideToggle(self, item: item)
        }

        actionStack.addArrangedSubview(playBtn)
        actionStack.addArrangedSubview(pinBtn)
        actionStack.addArrangedSubview(searchBtn)
        actionStack.addArrangedSubview(hideBtn)
    }

    private func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - AnkiCardCell (Twitter-feed card)

final class AnkiCardCell: UICollectionViewCell {
    static let reuseID = "AnkiCardCell"

    weak var delegate: TimelineCellDelegate?
    private var item: TimelineItem?

    private let avatarView = UIImageView()
    private let handleLabel = UILabel()
    private let dotLabel = UILabel()
    private let timestampLabel = UILabel()
    private let frontLabel = UILabel()
    private let backLabel = UILabel()
    private let headerStack = UIStackView()
    private let rightStack = UIStackView()
    private let actionStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        delegate = nil
        item = nil
    }

    private func setup() {
        applyCardStyle()

        avatarView.image = UIImage(systemName: "brain.headspans")
        avatarView.tintColor = .systemPurple
        avatarView.contentMode = .center
        avatarView.backgroundColor = .systemPurple.withAlphaComponent(0.12)
        avatarView.layer.cornerRadius = 18
        avatarView.clipsToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        handleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        handleLabel.textColor = .label
        handleLabel.text = "@anki_deck"

        dotLabel.text = "•"
        dotLabel.font = .preferredFont(forTextStyle: .caption1)
        dotLabel.textColor = .tertiaryLabel

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .secondaryLabel

        headerStack.axis = .horizontal
        headerStack.spacing = 4
        headerStack.alignment = .firstBaseline
        headerStack.addArrangedSubview(handleLabel)
        headerStack.addArrangedSubview(dotLabel)
        headerStack.addArrangedSubview(timestampLabel)

        frontLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        frontLabel.textColor = .label
        frontLabel.numberOfLines = 0

        backLabel.font = .preferredFont(forTextStyle: .caption1)
        backLabel.textColor = .secondaryLabel
        backLabel.numberOfLines = 2

        actionStack.axis = .horizontal
        actionStack.spacing = 2
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        rightStack.axis = .vertical
        rightStack.spacing = 4
        rightStack.alignment = .leading
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(headerStack)
        rightStack.addArrangedSubview(frontLabel)
        rightStack.addArrangedSubview(backLabel)
        rightStack.addArrangedSubview(actionStack)

        contentView.addSubview(avatarView)
        contentView.addSubview(rightStack)

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            rightStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        self.item = item
        frontLabel.text = item.title
        backLabel.text = item.subtitle
        backLabel.isHidden = item.subtitle?.isEmpty ?? true
        timestampLabel.text = formatHMS(item.audioStartTime)
        contentView.alpha = isHistory ? 0.65 : 1.0

        rebuildActions(for: item)
    }

    private func rebuildActions(for item: TimelineItem) {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let playBtn = makeActionButton(systemName: "play.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPlay(self, item: item)
        }
        let pinBtn = makeActionButton(systemName: "pin.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPin(self, item: item)
        }
        let searchBtn = makeActionButton(systemName: "magnifyingglass") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapSearch(self, item: item)
        }
        let eyeIcon = item.isEnabled ? "eye.slash" : "eye"
        let hideBtn = makeActionButton(systemName: eyeIcon) { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapHideToggle(self, item: item)
        }

        actionStack.addArrangedSubview(playBtn)
        actionStack.addArrangedSubview(pinBtn)
        actionStack.addArrangedSubview(searchBtn)
        actionStack.addArrangedSubview(hideBtn)
    }

    private func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - ImageAssetCell (Twitter-feed card)

final class ImageAssetCell: UICollectionViewCell {
    static let reuseID = "ImageAssetCell"

    weak var delegate: TimelineCellDelegate?
    private var item: TimelineItem?

    private let avatarView = UIImageView()
    private let handleLabel = UILabel()
    private let dotLabel = UILabel()
    private let timestampLabel = UILabel()
    private let anchorIcon = UIImageView()
    private let assetImageView = UIImageView()
    private let captionLabel = UILabel()
    private let headerStack = UIStackView()
    private let rightStack = UIStackView()
    private let actionStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        delegate = nil
        item = nil
        assetImageView.image = nil
    }

    private func setup() {
        applyCardStyle()

        avatarView.image = UIImage(systemName: "photo")
        avatarView.tintColor = .systemTeal
        avatarView.contentMode = .center
        avatarView.backgroundColor = .systemTeal.withAlphaComponent(0.12)
        avatarView.layer.cornerRadius = 18
        avatarView.clipsToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        handleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        handleLabel.textColor = .label
        handleLabel.text = "@photo_store"

        dotLabel.text = "•"
        dotLabel.font = .preferredFont(forTextStyle: .caption1)
        dotLabel.textColor = .tertiaryLabel

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .secondaryLabel

        anchorIcon.image = UIImage(systemName: "link.circle")
        anchorIcon.tintColor = .systemGreen
        anchorIcon.translatesAutoresizingMaskIntoConstraints = false
        anchorIcon.isHidden = true
        anchorIcon.contentMode = .scaleAspectFit

        headerStack.axis = .horizontal
        headerStack.spacing = 4
        headerStack.alignment = .firstBaseline
        headerStack.addArrangedSubview(handleLabel)
        headerStack.addArrangedSubview(dotLabel)
        headerStack.addArrangedSubview(timestampLabel)
        headerStack.addArrangedSubview(anchorIcon)
        headerStack.setCustomSpacing(4, after: timestampLabel)

        assetImageView.contentMode = .scaleAspectFit
        assetImageView.clipsToBounds = true
        assetImageView.layer.cornerRadius = 8
        assetImageView.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.textColor = .secondaryLabel
        captionLabel.numberOfLines = 0

        actionStack.axis = .horizontal
        actionStack.spacing = 2
        actionStack.distribution = .fillEqually
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        rightStack.axis = .vertical
        rightStack.spacing = 4
        rightStack.alignment = .leading
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(headerStack)
        rightStack.addArrangedSubview(assetImageView)
        rightStack.addArrangedSubview(captionLabel)
        rightStack.addArrangedSubview(actionStack)

        contentView.addSubview(avatarView)
        contentView.addSubview(rightStack)

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            rightStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rightStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            assetImageView.widthAnchor.constraint(lessThanOrEqualTo: rightStack.widthAnchor, multiplier: 0.8),
            assetImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        self.item = item
        captionLabel.text = item.title
        timestampLabel.text = formatHMS(item.audioStartTime)
        anchorIcon.isHidden = item.alignmentStatus != "lockedAnchor"
        contentView.alpha = isHistory ? 0.65 : 1.0

        if let path = item.imagePath,
           let image = UIImage(contentsOfFile: path) {
            assetImageView.image = image
            assetImageView.isHidden = false
        } else {
            assetImageView.isHidden = true
        }
        timestampLabel.text = formatHMS(item.audioStartTime)
        contentView.alpha = isHistory ? 0.65 : 1.0

        rebuildActions(for: item)
    }

    private func rebuildActions(for item: TimelineItem) {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let playBtn = makeActionButton(systemName: "play.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPlay(self, item: item)
        }
        let pinBtn = makeActionButton(systemName: "pin.fill") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapPin(self, item: item)
        }
        let searchBtn = makeActionButton(systemName: "magnifyingglass") { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapSearch(self, item: item)
        }
        let eyeIcon = item.isEnabled ? "eye.slash" : "eye"
        let hideBtn = makeActionButton(systemName: eyeIcon) { [weak self] in
            guard let self, let item = self.item else { return }
            self.delegate?.timelineCellDidTapHideToggle(self, item: item)
        }

        actionStack.addArrangedSubview(playBtn)
        actionStack.addArrangedSubview(pinBtn)
        actionStack.addArrangedSubview(searchBtn)
        actionStack.addArrangedSubview(hideBtn)
    }

    private func formatHMS(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - NowLineCell

final class NowLineCell: UICollectionViewCell {
    static let reuseID = "NowLineCell"

    private let line = UIView()
    private let label = UILabel()
    private let leftLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .clear

        leftLine.backgroundColor = .systemRed
        leftLine.translatesAutoresizingMaskIntoConstraints = false

        line.backgroundColor = .systemRed
        line.translatesAutoresizingMaskIntoConstraints = false

        label.text = "NOW"
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .systemRed
        label.textAlignment = .center
        label.backgroundColor = .systemRed.withAlphaComponent(0.1)
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(leftLine)
        contentView.addSubview(label)
        contentView.addSubview(line)

        NSLayoutConstraint.activate([
            leftLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            leftLine.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            leftLine.widthAnchor.constraint(equalToConstant: 12),
            leftLine.heightAnchor.constraint(equalToConstant: 2),

            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leftLine.trailingAnchor, constant: 6),
            label.widthAnchor.constraint(equalToConstant: 44),
            label.heightAnchor.constraint(equalToConstant: 20),

            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            line.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            line.heightAnchor.constraint(equalToConstant: 2),
        ])
    }
}

// MARK: - ElasticScrubberCell

final class ElasticScrubberCell: UICollectionViewCell {
    static let reuseID = "ElasticScrubberCell"

    private let gapLabel = UILabel()
    private let topDot = UIView()
    private let bottomDot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .clear

        gapLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        gapLabel.textColor = .tertiaryLabel
        gapLabel.textAlignment = .center
        gapLabel.translatesAutoresizingMaskIntoConstraints = false

        topDot.backgroundColor = .quaternaryLabel
        topDot.layer.cornerRadius = 3
        topDot.translatesAutoresizingMaskIntoConstraints = false

        bottomDot.backgroundColor = .quaternaryLabel
        bottomDot.layer.cornerRadius = 3
        bottomDot.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(gapLabel)
        contentView.addSubview(topDot)
        contentView.addSubview(bottomDot)

        NSLayoutConstraint.activate([
            topDot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            topDot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            topDot.widthAnchor.constraint(equalToConstant: 6),
            topDot.heightAnchor.constraint(equalToConstant: 6),

            gapLabel.topAnchor.constraint(equalTo: topDot.bottomAnchor, constant: 6),
            gapLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            gapLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            bottomDot.topAnchor.constraint(equalTo: gapLabel.bottomAnchor, constant: 6),
            bottomDot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            bottomDot.widthAnchor.constraint(equalToConstant: 6),
            bottomDot.heightAnchor.constraint(equalToConstant: 6),
            bottomDot.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    func configure(gapDuration: TimeInterval) {
        let minutes = Int(gapDuration / 60)
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            gapLabel.text = "\(h)h \(m)m gap"
        } else {
            gapLabel.text = "\(minutes)m gap"
        }
    }
}

// MARK: - Sticky Review Header

final class StickyReviewHeaderView: UICollectionReusableView {
    static let reuseID = "StickyReviewHeaderView"

    private let frontLabel = UILabel()
    private let backLabel = UILabel()
    private let gradeStack = UIStackView()
    private let dismissButton = UIButton(type: .system)
    private var gradeAction: ((Int) -> Void)?
    private var dismissAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .systemPurple.withAlphaComponent(0.12)
        layer.cornerRadius = 12
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        frontLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        frontLabel.textColor = .label
        frontLabel.numberOfLines = 2
        frontLabel.translatesAutoresizingMaskIntoConstraints = false

        backLabel.font = .preferredFont(forTextStyle: .caption1)
        backLabel.textColor = .secondaryLabel
        backLabel.numberOfLines = 2
        backLabel.translatesAutoresizingMaskIntoConstraints = false

        gradeStack.axis = .horizontal
        gradeStack.spacing = 4
        gradeStack.distribution = .fillEqually
        gradeStack.translatesAutoresizingMaskIntoConstraints = false

        for grade in 0..<6 {
            let btn = UIButton(type: .system)
            btn.setTitle("\(grade)", for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            btn.backgroundColor = gradeColor(grade).withAlphaComponent(0.15)
            btn.setTitleColor(gradeColor(grade), for: .normal)
            btn.layer.cornerRadius = 6
            btn.tag = grade
            btn.addTarget(self, action: #selector(gradeTapped(_:)), for: .touchUpInside)
            gradeStack.addArrangedSubview(btn)
        }

        dismissButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        dismissButton.tintColor = .secondaryLabel
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        addSubview(frontLabel)
        addSubview(backLabel)
        addSubview(gradeStack)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            frontLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            frontLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            frontLabel.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),

            backLabel.topAnchor.constraint(equalTo: frontLabel.bottomAnchor, constant: 4),
            backLabel.leadingAnchor.constraint(equalTo: frontLabel.leadingAnchor),
            backLabel.trailingAnchor.constraint(equalTo: frontLabel.trailingAnchor),

            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dismissButton.widthAnchor.constraint(equalToConstant: 24),
            dismissButton.heightAnchor.constraint(equalToConstant: 24),

            gradeStack.topAnchor.constraint(equalTo: backLabel.bottomAnchor, constant: 8),
            gradeStack.leadingAnchor.constraint(equalTo: frontLabel.leadingAnchor),
            gradeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            gradeStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            gradeStack.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func configure(
        frontText: String,
        backText: String?,
        onGrade: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        frontLabel.text = frontText
        backLabel.text = backText
        backLabel.isHidden = backText?.isEmpty ?? true
        gradeAction = onGrade
        dismissAction = onDismiss
    }

    @objc private func gradeTapped(_ sender: UIButton) {
        gradeAction?(sender.tag)
    }

    @objc private func dismissTapped() {
        dismissAction?()
    }

    private func gradeColor(_ grade: Int) -> UIColor {
        switch grade {
        case 0: return .systemRed
        case 1, 2: return .systemOrange
        case 3, 4: return .systemGreen
        case 5: return .systemBlue
        default: return .systemGray
        }
    }
}

// MARK: - Font Helpers

private func monospacedDigitFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
    let size = UIFont.preferredFont(forTextStyle: style).pointSize
    return UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
