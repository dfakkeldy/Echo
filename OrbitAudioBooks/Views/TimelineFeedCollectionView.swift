import SwiftUI
import UIKit

// MARK: - SwiftUI Wrapper

struct TimelineFeedCollectionView: UIViewRepresentable {
    @Binding var items: [TimelineDisplayItem]
    @Binding var currentPosition: TimeInterval
    var isFollowingPlayback: Bool
    var scrollTargetPosition: TimeInterval?
    var onUserScrolled: () -> Void
    var scrollToPosition: ((TimeInterval) -> Void)?

    /// Called when the user taps a feed item.
    var onItemTapped: ((TimelineDisplayItem) -> Void)?
    /// Called on long-press / context-menu to edit the item.
    var onContextMenuAction: ((TimelineDisplayItem) -> Void)?
    /// Called when the user requests deletion of a bookmark via context menu.
    var onDeleteBookmark: ((TimelineItem) -> Void)?

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

        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let displayIDs = items.map { $0.id }

        // Only rebuild the diffable snapshot when items actually change.
        // currentPosition updates 4×/second — rebuilding the snapshot on
        // every tick is wasteful and causes unnecessary cell reconfigs.
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
        context.coordinator.parent = self

        // Detect scroll target changes from the view model (via TimelineTab)
        // and trigger a programmatic scroll to center the NowLine.
        let previousTarget = context.coordinator.lastScrollTarget
        if let target = scrollTargetPosition, target != previousTarget {
            context.coordinator.lastScrollTarget = target
            if isFollowingPlayback {
                context.coordinator.scrollToNowLine(animated: true)
            }
        }

        // Auto-scroll the NowLine into view when following playback.
        if isFollowingPlayback {
            context.coordinator.scrollToNowLine(animated: true)
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
            section.interGroupSpacing = 2
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
                ) as! ElasticScrubberCell
                cell.configure(gapDuration: duration)
                return cell

            case .audiobookCard(let info):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: BookCardCell.reuseID, for: indexPath
                ) as! BookCardCell
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
            ) as! StickyReviewHeaderView
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
                c.configure(item, isHistory: isHistory)
            case let c as ChapterMarkerCell:
                c.configure(item, isHistory: isHistory)
            case let c as ImageAssetCell:
                c.configure(item, isHistory: isHistory)
            case let c as BookmarkCell:
                c.configure(item, isHistory: isHistory)
            case let c as AnkiCardCell:
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

                let edit = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                    self?.parent?.onContextMenuAction?(displayItem)
                }
                children.append(edit)

                // Add "Delete" for bookmark items
                if case .timelineItem(let item) = displayItem, item.itemType == .bookmark {
                    let delete = UIAction(
                        title: "Delete", image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { _ in
                        self?.parent?.onDeleteBookmark?(item)
                    }
                    children.append(delete)
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

// MARK: - Cell Types

final class TextSegmentCell: UICollectionViewCell {
    static let reuseID = "TextSegmentCell"

    private let label = UILabel()
    private let timestampLabel = UILabel()
    private let highlightBar = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .systemBlue.withAlphaComponent(0.06)
        contentView.layer.cornerRadius = 8

        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .tertiaryLabel
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false

        highlightBar.backgroundColor = .systemBlue
        highlightBar.layer.cornerRadius = 2
        highlightBar.isHidden = true
        highlightBar.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(label)
        contentView.addSubview(timestampLabel)
        contentView.addSubview(highlightBar)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            timestampLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            timestampLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            timestampLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            highlightBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0),
            highlightBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 0),
            highlightBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 0),
            highlightBar.widthAnchor.constraint(equalToConstant: 3),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        label.text = item.textPayload ?? item.title
        timestampLabel.text = formatHMS(item.audioStartTime)
        contentView.alpha = isHistory ? 0.65 : 1.0
    }

    func setActive(_ active: Bool) {
        highlightBar.isHidden = !active
        contentView.backgroundColor = active
            ? .systemBlue.withAlphaComponent(0.12)
            : .systemBlue.withAlphaComponent(0.06)
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

final class ChapterMarkerCell: UICollectionViewCell {
    static let reuseID = "ChapterMarkerCell"

    private let titleLabel = UILabel()
    private let durationLabel = UILabel()
    private let divider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .systemGray6

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        durationLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        durationLabel.textColor = .secondaryLabel
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(durationLabel)
        contentView.addSubview(divider)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            durationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            durationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1.0 / contentView.traitCollection.displayScale),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        titleLabel.text = item.title
        if let subtitle = item.subtitle {
            durationLabel.text = subtitle
        } else {
            durationLabel.text = formatHMS(item.audioStartTime)
        }
        contentView.alpha = isHistory ? 0.65 : 1.0
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

final class ImageAssetCell: UICollectionViewCell {
    static let reuseID = "ImageAssetCell"

    private let assetImageView = UIImageView()
    private let captionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .systemTeal.withAlphaComponent(0.06)
        contentView.layer.cornerRadius = 12

        assetImageView.contentMode = .scaleAspectFit
        assetImageView.clipsToBounds = true
        assetImageView.layer.cornerRadius = 8
        assetImageView.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.textColor = .secondaryLabel
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(assetImageView)
        contentView.addSubview(captionLabel)

        NSLayoutConstraint.activate([
            assetImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            assetImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            assetImageView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8),
            assetImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 300),

            captionLabel.topAnchor.constraint(equalTo: assetImageView.bottomAnchor, constant: 6),
            captionLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        captionLabel.text = item.title
        if let path = item.imagePath,
           let image = UIImage(contentsOfFile: path) {
            assetImageView.image = image
            assetImageView.isHidden = false
        } else {
            assetImageView.isHidden = true
        }
        contentView.alpha = isHistory ? 0.65 : 1.0
    }
}

final class BookmarkCell: UICollectionViewCell {
    static let reuseID = "BookmarkCell"

    private let bookmarkIcon = UIImageView()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let timestampLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .systemOrange.withAlphaComponent(0.08)
        contentView.layer.cornerRadius = 8

        bookmarkIcon.image = UIImage(systemName: "bookmark.fill")
        bookmarkIcon.tintColor = .systemOrange
        bookmarkIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        noteLabel.font = .preferredFont(forTextStyle: .caption1)
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 2
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .tertiaryLabel
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(bookmarkIcon)
        contentView.addSubview(titleLabel)
        contentView.addSubview(noteLabel)
        contentView.addSubview(timestampLabel)

        NSLayoutConstraint.activate([
            bookmarkIcon.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            bookmarkIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            bookmarkIcon.widthAnchor.constraint(equalToConstant: 16),
            bookmarkIcon.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.centerYAnchor.constraint(equalTo: bookmarkIcon.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: bookmarkIcon.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            noteLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            noteLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            timestampLabel.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 4),
            timestampLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            timestampLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        titleLabel.text = item.title
        noteLabel.text = item.subtitle
        noteLabel.isHidden = item.subtitle?.isEmpty ?? true
        timestampLabel.text = formatHMS(item.audioStartTime)
        contentView.alpha = isHistory ? 0.65 : 1.0
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

final class AnkiCardCell: UICollectionViewCell {
    static let reuseID = "AnkiCardCell"

    private let cardIcon = UIImageView()
    private let frontLabel = UILabel()
    private let backLabel = UILabel()
    private let timestampLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .systemPurple.withAlphaComponent(0.08)
        contentView.layer.cornerRadius = 8

        cardIcon.image = UIImage(systemName: "rectangle.fill.on.rectangle.fill")
        cardIcon.tintColor = .systemPurple
        cardIcon.translatesAutoresizingMaskIntoConstraints = false

        frontLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        frontLabel.translatesAutoresizingMaskIntoConstraints = false

        backLabel.font = .preferredFont(forTextStyle: .caption1)
        backLabel.textColor = .secondaryLabel
        backLabel.numberOfLines = 2
        backLabel.translatesAutoresizingMaskIntoConstraints = false

        timestampLabel.font = monospacedDigitFont(forTextStyle: .caption1)
        timestampLabel.textColor = .tertiaryLabel
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(cardIcon)
        contentView.addSubview(frontLabel)
        contentView.addSubview(backLabel)
        contentView.addSubview(timestampLabel)

        NSLayoutConstraint.activate([
            cardIcon.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            cardIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            cardIcon.widthAnchor.constraint(equalToConstant: 16),
            cardIcon.heightAnchor.constraint(equalToConstant: 16),

            frontLabel.centerYAnchor.constraint(equalTo: cardIcon.centerYAnchor),
            frontLabel.leadingAnchor.constraint(equalTo: cardIcon.trailingAnchor, constant: 8),
            frontLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            backLabel.topAnchor.constraint(equalTo: frontLabel.bottomAnchor, constant: 2),
            backLabel.leadingAnchor.constraint(equalTo: frontLabel.leadingAnchor),
            backLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            timestampLabel.topAnchor.constraint(equalTo: backLabel.bottomAnchor, constant: 4),
            timestampLabel.leadingAnchor.constraint(equalTo: frontLabel.leadingAnchor),
            timestampLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(_ item: TimelineItem, isHistory: Bool = false) {
        frontLabel.text = item.title
        backLabel.text = item.subtitle
        backLabel.isHidden = item.subtitle?.isEmpty ?? true
        timestampLabel.text = formatHMS(item.audioStartTime)
        contentView.alpha = isHistory ? 0.65 : 1.0
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
