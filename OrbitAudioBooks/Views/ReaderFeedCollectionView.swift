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
        context.coordinator.activeBlockID = activeBlockID

        let newCount = cards.count
        if newCount != context.coordinator.currentCardCount {
            context.coordinator.cards = cards
            context.coordinator.applySnapshot(animated: context.coordinator.currentCardCount > 0)
            context.coordinator.currentCardCount = newCount
        }

        context.coordinator.updateActiveBlock(activeBlockID, in: collectionView)
    }

    private func makeDataSource(for collectionView: UICollectionView) -> UICollectionViewDiffableDataSource<String, String> {
        return UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) {
            collectionView, indexPath, itemID in
            guard let coordinator = collectionView.delegate as? Coordinator else { return UICollectionViewCell() }
            return coordinator.cell(for: itemID, at: indexPath, collectionView: collectionView)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UICollectionViewDelegate {
        var onTapBlock: ((String) -> Void)?
        var onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?
        var settings: ReaderSettings = ReaderSettings(fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8")
        var dataSource: UICollectionViewDiffableDataSource<String, String>?
        var currentCardCount = 0
        var cards: [ReaderCardItem] = []
        var activeBlockID: String?

        init(onTapBlock: ((String) -> Void)?, onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?) {
            self.onTapBlock = onTapBlock
            self.onContextMenu = onContextMenu
        }

        func card(for id: String) -> ReaderCardItem? {
            cards.first { $0.id == id }
        }

        func cell(for itemID: String, at indexPath: IndexPath, collectionView: UICollectionView) -> UICollectionViewCell {
            guard let item = card(for: itemID) else { return UICollectionViewCell() }
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
                    cell.isActiveBlock = (block.id == activeBlockID) // not directly compared here
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
                    cell.isActiveBlock = (block.id == activeBlockID)
                    return cell
                }
            }
        }

        func applySnapshot(animated: Bool) {
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(cards.map(\.id), toSection: "main")
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        func updateActiveBlock(_ blockID: String?, in collectionView: UICollectionView) {
            // Clear previous highlight on all visible cells
            for cell in collectionView.visibleCells {
                (cell as? HeadingCardCell)?.isActiveBlock = false
                (cell as? ParagraphCardCell)?.isActiveBlock = false
            }

            guard let blockID, let snapshot = dataSource?.snapshot() else { return }
            let items = snapshot.itemIdentifiers
            for (idx, itemID) in items.enumerated() {
                guard case .block(let b) = card(for: itemID), b.id == blockID else { continue }
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

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                  case .block(let block) = card(for: itemID) else { return }
            onTapBlock?(block.id)
        }

        func collectionView(_ collectionView: UICollectionView,
                            contextMenuConfigurationForItemAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                  case .block(let block) = card(for: itemID) else { return nil }
            let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
            return onContextMenu?(block.id, kind)
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
