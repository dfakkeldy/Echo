import SwiftUI
import UIKit

// MARK: - SwiftUI Wrapper

struct TimelineFeedCollectionView: UIViewRepresentable {
    @Binding var items: [TimelineItem]
    @Binding var currentPosition: TimeInterval
    var isFollowingPlayback: Bool
    var onUserScrolled: () -> Void
    var scrollToPosition: ((TimeInterval) -> Void)?

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

        context.coordinator.collectionView = collectionView
        context.coordinator.parent = self

        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()

        let section = 0
        snapshot.appendSections([section])

        // Insert elastic scrubber cells for large time gaps
        var displayItems: [String] = []
        let gapThreshold: TimeInterval = 60.0

        for (index, item) in items.enumerated() {
            if index > 0 {
                let prev = items[index - 1]
                let gap = item.effectivePosition - prev.effectivePosition
                if gap > gapThreshold {
                    let gapID = "gap-\(prev.id)-to-\(item.id)"
                    displayItems.append(gapID)
                    context.coordinator.gapLookup[gapID] = gap
                }
            }
            displayItems.append(item.id)
        }

        snapshot.appendItems(displayItems, toSection: section)

        // Build item lookup for cell configuration
        var lookup: [String: TimelineItem] = [:]
        for item in items { lookup[item.id] = item }
        context.coordinator.itemLookup = lookup

        context.coordinator.dataSource.apply(snapshot, animatingDifferences: false)
        context.coordinator.currentItems = displayItems
    }

    static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
        coordinator.collectionView = nil
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { sectionIndex, environment in
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

            return section
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate {
        weak var collectionView: UICollectionView?
        var parent: TimelineFeedCollectionView?
        var currentItems: [String] = []
        var itemLookup: [String: TimelineItem] = [:]
        var gapLookup: [String: TimeInterval] = [:]
        private var isProgrammaticScroll = false

        lazy var dataSource: UICollectionViewDiffableDataSource<Int, String> = {
            guard let cv = collectionView else {
                fatalError("CollectionView not available for data source setup")
            }
            return UICollectionViewDiffableDataSource<Int, String>(
                collectionView: cv
            ) { [weak self] collectionView, indexPath, identifier in
                self?.cellProvider(collectionView, indexPath: indexPath, identifier: identifier)
            }
        }()

        private func cellProvider(
            _ collectionView: UICollectionView,
            indexPath: IndexPath,
            identifier: String
        ) -> UICollectionViewCell {
            if let item = itemLookup[identifier] {
                return configureItemCell(item, collectionView: collectionView, indexPath: indexPath)
            }
            if let gapDuration = gapLookup[identifier] {
                return configureElasticScrubberCell(
                    gapDuration,
                    collectionView: collectionView,
                    indexPath: indexPath
                )
            }
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: TextSegmentCell.reuseID, for: indexPath
            )
        }

        private func configureItemCell(
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

        private func configureElasticScrubberCell(
            _ gapDuration: TimeInterval,
            collectionView: UICollectionView,
            indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ElasticScrubberCell.reuseID, for: indexPath
            ) as! ElasticScrubberCell
            cell.configure(gapDuration: gapDuration)
            return cell
        }

        private func configure(cell: UICollectionViewCell, with item: TimelineItem) {
            switch cell {
            case let c as TextSegmentCell:
                c.configure(item)
            case let c as ChapterMarkerCell:
                c.configure(item)
            case let c as ImageAssetCell:
                c.configure(item)
            case let c as BookmarkCell:
                c.configure(item)
            case let c as AnkiCardCell:
                c.configure(item)
            default:
                break
            }
        }

        // MARK: - Scroll Detection

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll else { return }
            parent?.onUserScrolled()
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

        func scrollTo(position: TimeInterval, animated: Bool = true) {
            guard let cv = collectionView else { return }

            var bestIndex: Int?
            for (index, identifier) in currentItems.enumerated() {
                if let item = itemLookup[identifier] {
                    if position >= item.audioStartTime &&
                        (item.audioEndTime == nil || position < item.audioEndTime!) {
                        bestIndex = index
                        break
                    }
                    if item.audioStartTime <= position {
                        bestIndex = index
                    }
                    if item.audioStartTime > position {
                        break
                    }
                }
            }

            if let index = bestIndex {
                isProgrammaticScroll = true
                let indexPath = IndexPath(item: index, section: 0)
                cv.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.isProgrammaticScroll = false
                }
            }
        }
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

    func configure(_ item: TimelineItem) {
        label.text = item.textPayload ?? item.title
        timestampLabel.text = formatHMS(item.audioStartTime)
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
            divider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
    }

    func configure(_ item: TimelineItem) {
        titleLabel.text = item.title
        if let subtitle = item.subtitle {
            durationLabel.text = subtitle
        } else {
            durationLabel.text = formatHMS(item.audioStartTime)
        }
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

    func configure(_ item: TimelineItem) {
        captionLabel.text = item.title
        if let path = item.imagePath,
           let image = UIImage(contentsOfFile: path) {
            assetImageView.image = image
            assetImageView.isHidden = false
        } else {
            assetImageView.isHidden = true
        }
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

    func configure(_ item: TimelineItem) {
        titleLabel.text = item.title
        noteLabel.text = item.subtitle
        noteLabel.isHidden = item.subtitle?.isEmpty ?? true
        timestampLabel.text = formatHMS(item.audioStartTime)
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

    func configure(_ item: TimelineItem) {
        frontLabel.text = item.title
        backLabel.text = item.subtitle
        backLabel.isHidden = item.subtitle?.isEmpty ?? true
        timestampLabel.text = formatHMS(item.audioStartTime)
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
