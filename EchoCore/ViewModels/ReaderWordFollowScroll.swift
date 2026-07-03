// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure scroll policy for keeping the spoken word visible inside long reader
/// blocks. UIKit converts the active word rect into collection-view coordinates;
/// this helper only decides whether the content offset needs to move.
enum ReaderWordFollowScroll {
    static func targetOffsetY(
        currentOffsetY: Double,
        viewportHeight: Double,
        contentHeight: Double,
        wordMinY: Double,
        wordMaxY: Double,
        topMargin: Double = 96,
        bottomMargin: Double = 120
    ) -> Double? {
        guard viewportHeight > 0, contentHeight > viewportHeight, wordMaxY >= wordMinY else {
            return nil
        }

        let safeTopMargin = max(0, topMargin)
        let safeBottomMargin = max(0, bottomMargin)
        let visibleTop = currentOffsetY + safeTopMargin
        let visibleBottom = currentOffsetY + viewportHeight - safeBottomMargin

        if wordMinY >= visibleTop, wordMaxY <= visibleBottom {
            return nil
        }

        let wordHeight = max(1, wordMaxY - wordMinY)
        let centeredTop = (viewportHeight - wordHeight) / 2
        let desiredOffset = wordMinY - max(safeTopMargin, centeredTop)
        let maxOffset = max(0, contentHeight - viewportHeight)
        let clampedOffset = min(max(0, desiredOffset), maxOffset)

        guard abs(clampedOffset - currentOffsetY) >= 0.5 else { return nil }
        return clampedOffset
    }
}
