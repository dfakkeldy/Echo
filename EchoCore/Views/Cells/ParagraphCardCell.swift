import UIKit

/// Card cell for EPUB paragraph/sentence blocks. Renders HTML content via UITextView.
final class ParagraphCardCell: UICollectionViewCell {
    static let reuseIdentifier = "ParagraphCardCell"

    private let label: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
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

    func configure(with block: EPubBlockRecord, font: UIFont, tint: UIColor, lineSpacing: CGFloat, isExplicitHighlight: Bool, searchQuery: String? = nil) {
        let plainText = (block.text ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let textColor = isExplicitHighlight ? tint.contrastingTextColor : (UITraitCollection.current.userInterfaceStyle == .dark ? UIColor.white : UIColor.label)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: textColor
        ]

        let attributed = NSMutableAttributedString(string: plainText, attributes: baseAttributes)

        if let query = searchQuery, !query.isEmpty {
            let lowerText = plainText.lowercased()
            let lowerQuery = query.lowercased()
            var searchRange = lowerText.startIndex..<lowerText.endIndex
            while let range = lowerText.range(of: lowerQuery, options: .caseInsensitive, range: searchRange) {
                let nsRange = NSRange(range, in: plainText)
                attributed.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.4), range: nsRange)
                attributed.addAttribute(.font, value: UIFont.systemFont(ofSize: font.pointSize, weight: .bold), range: nsRange)
                searchRange = range.upperBound..<lowerText.endIndex
            }
        }

        label.attributedText = attributed
        contentView.backgroundColor = isExplicitHighlight ? tint : tint.withAlphaComponent(0.08)
    }
    
    func setManuallyAligned(_ isAnchored: Bool, timeString: String?) {
        anchorLabel.isHidden = false
        anchorLabel.text = timeString
        anchorLabel.textColor = isAnchored ? .systemRed : .secondaryLabel
    }
}
