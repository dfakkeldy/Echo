// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI
    import UIKit

    /// A bounded, scrollable paragraph. TextKit keeps the spoken word visible even
    /// when a single sentence is taller than the subtitle pane.
    struct VisualListeningSubtitleView: UIViewRepresentable {
        let cue: VisualListeningSubtitleCue
        let appFont: String

        @ScaledMetric(relativeTo: .headline) private var fontSize: CGFloat = 17

        func makeUIView(context: Context) -> FollowingSubtitleTextView {
            let view = FollowingSubtitleTextView(usingTextLayoutManager: false)
            view.backgroundColor = .clear
            view.isEditable = false
            view.isSelectable = false
            view.isScrollEnabled = true
            view.contentInsetAdjustmentBehavior = .never
            view.textContainerInset = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            view.textContainer.lineFragmentPadding = 0
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return view
        }

        func updateUIView(_ view: FollowingSubtitleTextView, context: Context) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSMutableAttributedString(
                string: cue.text,
                attributes: [
                    .font: font, .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: paragraph,
                ])
            let ranges = WordTokenizer.wordRanges(in: cue.text).map { NSRange($0, in: cue.text) }
            for (index, range) in ranges.enumerated() {
                if cue.activeWordIndex == index {
                    text.addAttribute(.foregroundColor, value: UIColor.label, range: range)
                } else if index < cue.alreadyHeardWordCount {
                    text.addAttribute(
                        .foregroundColor, value: UIColor.label.withAlphaComponent(0.72),
                        range: range)
                }
            }

            let index = cue.activeWordIndex ?? max(0, cue.alreadyHeardWordCount - 1)
            let followedRange =
                ranges.indices.contains(index) ? ranges[index] : NSRange(location: 0, length: 0)
            view.update(text: text, blockID: cue.blockID, followedRange: followedRange)
            view.accessibilityLabel = String(localized: "Subtitle: \(cue.text)")
        }

        private var font: UIFont {
            guard SettingsManager.normalizedAppFont(appFont) != SettingsManager.systemFontName,
                let custom = UIFont(name: appFont, size: fontSize)
            else { return .systemFont(ofSize: fontSize, weight: .semibold) }

            let descriptor = custom.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold.rawValue]
            ])
            return UIFont(descriptor: descriptor, size: fontSize)
        }
    }
#endif
