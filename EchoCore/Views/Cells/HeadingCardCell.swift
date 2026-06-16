// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Card cell for EPUB heading blocks (h1-h6). Larger font, more prominent background.
final class HeadingCardCell: UICollectionViewCell {
    static let reuseIdentifier = "HeadingCardCell"

    private let label: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .title3)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let activeBar: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBlue
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private let anchorLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .systemGreen
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private var hasAnchorText = false

    var isActiveBlock: Bool = false {
        didSet {
            activeBar.isHidden = !isActiveBlock
            contentView.alpha = isActiveBlock ? 1.0 : 0.95
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(label)
        contentView.addSubview(activeBar)
        contentView.addSubview(anchorLabel)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        NSLayoutConstraint.activate([
            activeBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            activeBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            activeBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            activeBar.widthAnchor.constraint(equalToConstant: 3),

            anchorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            anchorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with block: EPubBlockRecord, font: UIFont, tint: UIColor, isExplicitHighlight: Bool, searchQuery: String? = nil) {
        let plainText = (block.text ?? "").collapsedWhitespace()

        let hasThemeOrCardColor = block.cardColor != nil || block.chapterThemeColor != nil
        let textColor = hasThemeOrCardColor ? tint.contrastingTextColor : (UITraitCollection.current.userInterfaceStyle == .dark ? UIColor.white : UIColor.label)
        
        if let query = searchQuery, !query.isEmpty {
            label.attributedText = highlightedText(plainText, query: query, font: font, textColor: textColor)
        } else {
            label.text = plainText
            label.font = font
            label.textColor = textColor
        }
        
        if block.cardColor != nil {
            contentView.backgroundColor = tint
        } else if block.chapterThemeColor != nil {
            contentView.backgroundColor = UITraitCollection.current.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.2) : UIColor.white.withAlphaComponent(0.4)
        } else {
            contentView.backgroundColor = tint.withAlphaComponent(0.08)
        }
    }

    private func highlightedText(_ text: String, query: String, font: UIFont, textColor: UIColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])
        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()
        var searchRange = lowerText.startIndex..<lowerText.endIndex
        while let range = lowerText.range(of: lowerQuery, options: .caseInsensitive, range: searchRange) {
            let nsRange = NSRange(range, in: text)
            attributed.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.4), range: nsRange)
            attributed.addAttribute(.font, value: UIFont.systemFont(ofSize: font.pointSize, weight: .bold), range: nsRange)
            searchRange = range.upperBound..<lowerText.endIndex
        }
        return attributed
    }
    
    // Alignment debugging aid: every card shows its timestamp —
    // red = locked anchor, grey = interpolated.
    func setManuallyAligned(_ isAnchored: Bool, timeString: String?) {
        hasAnchorText = (timeString != nil)
        anchorLabel.text = timeString
        anchorLabel.textColor = isAnchored ? .systemRed : .secondaryLabel
        anchorLabel.isHidden = !hasAnchorText
    }
}
