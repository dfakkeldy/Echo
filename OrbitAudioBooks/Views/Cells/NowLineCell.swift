import UIKit

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
