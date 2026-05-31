import UIKit

// MARK: - Base Twitter-Feed Card Styling

extension UICollectionViewCell {
    func applyCardStyle() {
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.borderWidth = 1.0 / max(1, contentView.traitCollection.displayScale)
        contentView.layer.borderColor = UIColor.separator.cgColor
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.06
        contentView.layer.shadowRadius = 3
        contentView.layer.shadowOffset = CGSize(width: 0, height: 1)
        contentView.layer.masksToBounds = false
        layer.masksToBounds = false
    }
}

// MARK: - Action Footer Builder

func makeActionButton(systemName: String, action: @escaping () -> Void) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: systemName,
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    // Larger hit target while keeping 14pt icon size.
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    config.baseForegroundColor = .secondaryLabel
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
}

// MARK: - Font Helpers

func monospacedDigitFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
    let size = UIFont.preferredFont(forTextStyle: style).pointSize
    return UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
}

extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
