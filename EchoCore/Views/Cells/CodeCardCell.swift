// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
import UIKit

/// Card cell for `.code` blocks: monospaced, theme-aware, selectable code with
/// horizontal scrolling for long lines (code is never wrapped). Narration uses
/// block-level highlighting because it speaks only the block's short cue.
final class CodeCardCell: UICollectionViewCell {
    static let reuseIdentifier = "CodeCardCell"

    private static let maxCodeHeight: CGFloat = 320

    private let textView: UITextView = {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.backgroundColor = .clear
        textView.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }()

    private let languageLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var textViewHeight: NSLayoutConstraint?

    var isActiveBlock: Bool = false {
        didSet { updateActiveAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(textView)
        contentView.addSubview(languageLabel)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.borderWidth = 0

        let height = textView.heightAnchor.constraint(equalToConstant: 60)
        textViewHeight = height
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -14
            ),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            height,

            languageLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 14
            ),
            languageLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -14
            ),
            languageLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 6),
            languageLabel.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -12
            ),
        ])

        _ = registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: CodeCardCell, _: UITraitCollection) in
            cell.updateFontAndHeight()
            cell.invalidateCollectionLayoutForTraitChange()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with block: EPubBlockRecord, tint: UIColor) {
        let code = block.text ?? ""
        textView.text = code
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.setContentOffset(.zero, animated: false)
        languageLabel.text = block.codeLanguage
        languageLabel.isHidden = block.codeLanguage == nil
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.borderColor = tint.cgColor
        updateFontAndHeight()
        updateActiveAppearance()
    }

    func configureAccessibility(
        label accessibilityLabel: String,
        hint accessibilityHint: String,
        actions: [UIAccessibilityCustomAction]
    ) {
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityLabel
        accessibilityValue = textView.text
        self.accessibilityHint = accessibilityHint
        accessibilityTraits = [.button]
        accessibilityCustomActions = actions
        textView.isAccessibilityElement = false
        languageLabel.isAccessibilityElement = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.text = nil
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.setContentOffset(.zero, animated: false)
        languageLabel.text = nil
        languageLabel.isHidden = true
        textViewHeight?.constant = 60
        isActiveBlock = false
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.borderColor = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityCustomActions = nil
    }

    private func updateFontAndHeight() {
        textView.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(
                forTextStyle: .callout,
                compatibleWith: traitCollection
            ).pointSize,
            weight: .regular
        )

        let code = textView.text ?? ""
        let lineHeight = textView.font?.lineHeight ?? 17
        let lineCount = max(1, code.components(separatedBy: "\n").count)
        let fitted = CGFloat(lineCount) * lineHeight
            + textView.textContainerInset.top + textView.textContainerInset.bottom
        textViewHeight?.constant = min(fitted, Self.maxCodeHeight)
    }

    private func invalidateCollectionLayoutForTraitChange() {
        (superview as? UICollectionView)?.collectionViewLayout.invalidateLayout()
    }

    private func updateActiveAppearance() {
        contentView.layer.borderWidth = isActiveBlock ? 2 : 0
    }
}
#endif
