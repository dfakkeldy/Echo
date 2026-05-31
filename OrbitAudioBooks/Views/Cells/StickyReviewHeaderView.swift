import UIKit

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
