// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import UIKit

    /// Defers following until TextKit has the pane's real bounds, including after
    /// rotation or a Dynamic Type change. A finger scroll takes priority.
    final class FollowingSubtitleTextView: UITextView {
        private var blockID: String?
        private var followedRange = NSRange(location: 0, length: 0)
        private var needsFollow = true
        private var previousSize: CGSize = .zero
        private var previousFont: UIFont?

        func update(text: NSAttributedString, blockID: String, followedRange: NSRange) {
            if self.blockID != blockID || self.text != text.string {
                self.blockID = blockID
                needsFollow = true
                setContentOffset(.zero, animated: false)
            }
            if !attributedText.isEqual(to: text) {
                textStorage.setAttributedString(text)
            }
            let font =
                text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
            if font != previousFont {
                previousFont = font
                needsFollow = true
            }
            if self.followedRange != followedRange {
                self.followedRange = followedRange
                needsFollow = true
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != previousSize {
                previousSize = bounds.size
                needsFollow = true
            }
            guard needsFollow, bounds.width > 0, bounds.height > 0,
                !isTracking, !isDragging, !isDecelerating
            else { return }

            needsFollow = false
            layoutManager.ensureLayout(for: textContainer)
            scrollRangeToVisible(followedRange)
        }
    }
#endif
