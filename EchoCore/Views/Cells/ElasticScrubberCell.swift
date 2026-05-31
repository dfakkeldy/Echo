import UIKit

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
