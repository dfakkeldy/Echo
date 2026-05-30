import SwiftUI
import UIKit

/// UIViewRepresentable wrapping a UICollectionView that renders the EPUB reader feed.
struct ReaderFeedCollectionView: UIViewRepresentable {
    @Binding var cards: [ReaderCardItem]
    @Binding var activeBlockID: String?
    let settings: ReaderSettings
    var onTapBlock: ((String) -> Void)?
    var onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTapBlock: onTapBlock,
            onContextMenu: onContextMenu
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
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            return section
        }

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = context.coordinator

        collectionView.register(HeadingCardCell.self, forCellWithReuseIdentifier: HeadingCardCell.reuseIdentifier)
        collectionView.register(ParagraphCardCell.self, forCellWithReuseIdentifier: ParagraphCardCell.reuseIdentifier)
        collectionView.register(ImageCardCell.self, forCellWithReuseIdentifier: ImageCardCell.reuseIdentifier)
        collectionView.register(ChapterDividerCell.self, forCellWithReuseIdentifier: ChapterDividerCell.reuseIdentifier)

        context.coordinator.dataSource = makeDataSource(for: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.onTapBlock = onTapBlock
        context.coordinator.onContextMenu = onContextMenu
        context.coordinator.settings = settings

        let newCount = cards.count
        if newCount != context.coordinator.currentCardCount {
            context.coordinator.applySnapshot(cards: cards, animated: context.coordinator.currentCardCount > 0)
            context.coordinator.currentCardCount = newCount
        }

        context.coordinator.updateActiveBlock(activeBlockID, in: collectionView)
    }

    private func makeDataSource(for collectionView: UICollectionView) -> UICollectionViewDiffableDataSource<String, ReaderCardItem> {
        return UICollectionViewDiffableDataSource<String, ReaderCardItem>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .chapterHeader(let title, _):
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ChapterDividerCell.reuseIdentifier, for: indexPath
                ) as? ChapterDividerCell else { return UICollectionViewCell() }
                cell.configure(with: title)
                return cell

            case .block(let block):
                switch block.blockKind {
                case EPubBlockRecord.Kind.heading.rawValue:
                    guard let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: HeadingCardCell.reuseIdentifier, for: indexPath
                    ) as? HeadingCardCell else { return UICollectionViewCell() }
                    let font = UIFont(name: "Lexend-SemiBold", size: 20) ?? UIFont.preferredFont(forTextStyle: .title3)
                    let cardTint = UIColor(hex: block.cardColor ?? "") ?? UIColor.systemBackground
                    cell.configure(with: block.text ?? "", font: font, tint: cardTint)
                    cell.isActiveBlock = (block.id == self.activeBlockID)
                    return cell

                case EPubBlockRecord.Kind.image.rawValue:
                    guard let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: ImageCardCell.reuseIdentifier, for: indexPath
                    ) as? ImageCardCell else { return UICollectionViewCell() }
                    let cardTint = UIColor(hex: block.cardColor ?? "") ?? UIColor.systemBackground
                    cell.configure(with: block, tint: cardTint)
                    return cell

                default:
                    guard let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: ParagraphCardCell.reuseIdentifier, for: indexPath
                    ) as? ParagraphCardCell else { return UICollectionViewCell() }
                    let font = UIFont(name: "Lexend-Regular", size: 17) ?? UIFont.preferredFont(forTextStyle: .body)
                    let cardTint = UIColor(hex: block.cardColor ?? "") ?? UIColor.systemBackground
                    cell.configure(with: block, font: font, tint: cardTint, lineSpacing: 4)
                    cell.isActiveBlock = (block.id == self.activeBlockID)
                    return cell
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UICollectionViewDelegate {
        var onTapBlock: ((String) -> Void)?
        var onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?
        var settings: ReaderSettings = ReaderSettings(fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8")
        var dataSource: UICollectionViewDiffableDataSource<String, ReaderCardItem>?
        var currentCardCount = 0

        init(onTapBlock: ((String) -> Void)?, onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?) {
            self.onTapBlock = onTapBlock
            self.onContextMenu = onContextMenu
        }

        func applySnapshot(cards: [ReaderCardItem], animated: Bool) {
            var snapshot = NSDiffableDataSourceSnapshot<String, ReaderCardItem>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(cards, toSection: "main")
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        func updateActiveBlock(_ blockID: String?, in collectionView: UICollectionView) {
            guard let blockID, let snapshot = dataSource?.snapshot() else { return }
            let items = snapshot.itemIdentifiers
            for (idx, item) in items.enumerated() {
                if case .block(let b) = item, b.id == blockID {
                    let indexPath = IndexPath(item: idx, section: 0)
                    if let cell = collectionView.cellForItem(at: indexPath) {
                        if let headingCell = cell as? HeadingCardCell {
                            headingCell.isActiveBlock = true
                        } else if let paraCell = cell as? ParagraphCardCell {
                            paraCell.isActiveBlock = true
                        }
                    }
                    if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
                        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
                    }
                    break
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            if case .block(let block) = item {
                onTapBlock?(block.id)
            }
        }

        func collectionView(_ collectionView: UICollectionView,
                            contextMenuConfigurationForItemAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            if case .block(let block) = item {
                let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
                return onContextMenu?(block.id, kind)
            }
            return nil
        }
    }
}

// MARK: - Chapter Divider Cell

fileprivate final class ChapterDividerCell: UICollectionViewCell {
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
