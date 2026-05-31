import UIKit

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

        dotLabel.text = "\u{2022}"
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
