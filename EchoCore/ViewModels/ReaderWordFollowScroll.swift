// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure scroll policy for centering the spoken line in a reader viewport.
/// UIKit converts word and paragraph bounds into collection-view coordinates;
/// this helper only decides whether the content offset needs to move.
nonisolated enum ReaderWordFollowScroll {
    static func preferredRange(
        wordLine: ClosedRange<Double>?,
        paragraph: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        wordLine ?? paragraph
    }

    /// Temporary compatibility overload for the collection-view caller.
    /// Task 4 migrates that caller to the line-range API and removes this shim.
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

        return targetOffsetY(
            currentOffsetY: currentOffsetY,
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
            targetRange: wordMinY ... wordMaxY,
            topInset: topMargin,
            bottomInset: bottomMargin
        )
    }

    static func targetOffsetY(
        currentOffsetY: Double,
        viewportHeight: Double,
        contentHeight: Double,
        targetRange: ClosedRange<Double>,
        topInset: Double,
        bottomInset: Double,
        tolerance: Double = 0.5
    ) -> Double? {
        guard viewportHeight > 0, contentHeight > 0 else { return nil }

        let safeTopInset = max(0, topInset)
        let safeBottomInset = max(0, bottomInset)
        let usableHeight = max(1, viewportHeight - safeTopInset - safeBottomInset)
        let usableCenter = safeTopInset + usableHeight / 2
        let targetCenter = (targetRange.lowerBound + targetRange.upperBound) / 2
        let desiredOffset = targetCenter - usableCenter
        let minimumOffset = -safeTopInset
        let maximumOffset = max(
            minimumOffset,
            contentHeight - viewportHeight + safeBottomInset
        )
        let clampedOffset = min(maximumOffset, max(minimumOffset, desiredOffset))

        guard abs(clampedOffset - currentOffsetY) >= tolerance else { return nil }
        return clampedOffset
    }
}
