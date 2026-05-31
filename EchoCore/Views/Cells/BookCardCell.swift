import UIKit

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
