import UIKit

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

        dotLabel.text = "\u{2022}"
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
