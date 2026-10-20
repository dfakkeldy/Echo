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

        func update(text: NSAttributedString, blockID: String, followedRange: NSRange) {
            let blockChanged = self.blockID != blockID || self.text != text.string
            let textChanged = !textStorage.isEqual(to: text)
            let followChanged = self.followedRange != followedRange
            self.blockID = blockID
            self.followedRange = followedRange
            if textChanged { textStorage.setAttributedString(text) }
            if blockChanged { setContentOffset(.zero, animated: false) }
            needsFollow = needsFollow || blockChanged || textChanged || followChanged
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
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: followedRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
            scrollRectToVisible(rect, animated: false)
        }
    }
#endif
