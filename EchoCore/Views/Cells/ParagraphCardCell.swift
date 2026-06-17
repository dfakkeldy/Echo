// SPDX-License-Identifier: GPL-3.0-or-later
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

    private var hasAnchorText = false

    // Karaoke word-highlight state. Word ranges are computed once at configure
    // time so repeated words don't break a naive substring search; the highlight
    // is then applied/cleared against `baseAttributed` without rebuilding text.
    private var wordRanges: [NSRange] = []
    private var baseAttributed: NSMutableAttributedString?
    private var highlightTint: UIColor = .systemBlue
    private var lastHighlightFont: UIFont = .systemFont(ofSize: 16)

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

            anchorLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -8),
            anchorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(
        with block: EPubBlockRecord, font: UIFont, tint: UIColor, lineSpacing: CGFloat,
        isExplicitHighlight: Bool, searchQuery: String? = nil,
        highlightedWordIndex: Int? = nil
    ) {
        let plainText = (block.text ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let hasThemeOrCardColor = block.cardColor != nil || block.chapterThemeColor != nil
        let textColor =
            hasThemeOrCardColor
            ? tint.contrastingTextColor
            : (UITraitCollection.current.userInterfaceStyle == .dark
                ? UIColor.white : UIColor.label)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: textColor,
        ]

        let attributed = NSMutableAttributedString(string: plainText, attributes: baseAttributes)

        if let query = searchQuery, !query.isEmpty {
            let lowerText = plainText.lowercased()
            let lowerQuery = query.lowercased()
            var searchRange = lowerText.startIndex..<lowerText.endIndex
            while let range = lowerText.range(
                of: lowerQuery, options: .caseInsensitive, range: searchRange)
            {
                let nsRange = NSRange(range, in: plainText)
                attributed.addAttribute(
                    .backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.4),
                    range: nsRange)
                attributed.addAttribute(
                    .font, value: UIFont.systemFont(ofSize: font.pointSize, weight: .bold),
                    range: nsRange)
                searchRange = range.upperBound..<lowerText.endIndex
            }
        }

        // Compute rendered-word ranges (word boundaries) once for karaoke, then
        // apply the highlight against this base text instead of mutating it in place.
        wordRanges = Self.wordRanges(in: plainText)
        baseAttributed = attributed
        highlightTint = tint
        applyWordHighlight(highlightedWordIndex, baseFont: font)

        if block.cardColor != nil {
            contentView.backgroundColor = tint
        } else if block.chapterThemeColor != nil {
            contentView.backgroundColor =
                UITraitCollection.current.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.2) : UIColor.white.withAlphaComponent(0.4)
        } else {
            contentView.backgroundColor = tint.withAlphaComponent(0.08)
        }
    }

    // Alignment debugging aid: every card shows its timestamp —
    // red = locked anchor, grey = interpolated.
    func setManuallyAligned(_ isAnchored: Bool, timeString: String?) {
        hasAnchorText = (timeString != nil)
        anchorLabel.text = timeString
        anchorLabel.textColor = isAnchored ? .systemRed : .secondaryLabel
        anchorLabel.isHidden = !hasAnchorText
    }

    /// Word boundary ranges over `text`, matching the word order the timing
    /// interpolator produces, so word index N maps to the same rendered word.
    static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byWords
        ) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    /// Applies (or clears) the karaoke highlight without rebuilding base text.
    func applyWordHighlight(_ wordIndex: Int?, baseFont: UIFont) {
        guard let base = baseAttributed?.mutableCopy() as? NSMutableAttributedString else { return }
        if let wordIndex, wordIndex >= 0, wordIndex < wordRanges.count {
            let range = wordRanges[wordIndex]
            base.addAttribute(
                .backgroundColor,
                value: highlightTint.withAlphaComponent(0.25), range: range)
            base.addAttribute(
                .font,
                value: UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                range: range)
        }
        label.attributedText = base
        lastHighlightFont = baseFont
    }
}
