// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

/// Feed row for a standalone voice memo. The play button fires `onPlay` so a tap
/// plays the audio without triggering collection-view cell selection.
final class VoiceMemoFeedCell: UICollectionViewCell {
    static let reuseIdentifier = "VoiceMemoFeedCell"

    private var onPlay: (() -> Void)?

    private let container: UIView = {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.layer.cornerRadius = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let playButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        b.tintColor = .systemBlue
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let label: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .callout)
        l.textColor = .label
        l.adjustsFontForContentSizeCategory = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerCurve = .continuous
        contentView.addSubview(container)
        container.addSubview(playButton)
        container.addSubview(label)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            playButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            playButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 28),
            playButton.heightAnchor.constraint(equalToConstant: 28),

            label.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(durationText: String, tint: UIColor, onPlay: @escaping () -> Void) {
        label.text = durationText
        self.onPlay = onPlay
        playButton.tintColor = tint
        container.backgroundColor = tint.withAlphaComponent(0.08)
        accessibilityLabel = "Voice memo, \(durationText)"
    }

    @objc private func playTapped() {
        onPlay?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPlay = nil
    }
}
