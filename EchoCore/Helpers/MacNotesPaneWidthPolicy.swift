// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Width policy for the reader | Notes boundary laid out by `MacReaderNotesSplit`.
///
/// Pure arithmetic so it can be tested headlessly. Every result is finite and
/// non-negative whatever geometry is proposed. When the reader minimum and the
/// Notes minimum cannot both fit, Notes yields (width 0) instead of demanding
/// more width than the window offers. The preferred width is kept apart from
/// the laid-out width, so it survives hiding Notes and passing narrow windows.
nonisolated struct MacNotesPaneWidthPolicy: Equatable, Sendable {
    var readerMinimum: CGFloat = 320
    var notesMinimum: CGFloat = 220
    var notesIdeal: CGFloat = 320
    var notesMaximum: CGFloat = 520
    var dividerWidth: CGFloat = 9

    static let standard = MacNotesPaneWidthPolicy()

    /// Stable minimum advertised to the containing navigation detail column.
    /// This keeps a shown Notes pane usable during an ordinary window resize.
    func minimumContainerWidth(isNotesShown: Bool) -> CGFloat {
        readerMinimum + (isNotesShown ? notesMinimum + dividerWidth : 0)
    }

    /// The preferred width brought into `notesMinimum...notesMaximum`; nonfinite falls back to ideal.
    func clampedPreferred(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return notesIdeal }
        return min(max(width, notesMinimum), notesMaximum)
    }

    /// Widest Notes that still leaves the reader its minimum, or `nil` when Notes cannot fit.
    func notesUpperBound(available: CGFloat) -> CGFloat? {
        let room = sanitized(available) - readerMinimum - dividerWidth
        guard room >= notesMinimum else { return nil }
        return min(room, notesMaximum)
    }

    /// Notes width to lay out: 0 when hidden or when it cannot fit beside the reader.
    func notesWidth(preferred: CGFloat, available: CGFloat, isShown: Bool) -> CGFloat {
        guard isShown, let upper = notesUpperBound(available: available) else { return 0 }
        return min(clampedPreferred(preferred), upper)
    }

    /// Reader width for a laid-out Notes width; the reader gets everything when Notes is 0.
    func readerWidth(notesWidth: CGFloat, available: CGFloat) -> CGFloat {
        let used = notesWidth > 0 ? notesWidth + dividerWidth : 0
        return max(0, sanitized(available) - used)
    }

    /// Preferred width after moving the divider `translation` points from a drag
    /// that began at `startWidth`. In a right-to-left layout Notes is on the
    /// physical leading edge, so moving right widens it instead.
    /// Always measured from the drag start, never accumulated per event.
    func dragged(
        startWidth: CGFloat, translation: CGFloat, available: CGFloat,
        notesOnLeadingEdge: Bool = false
    ) -> CGFloat {
        let start = clampedPreferred(startWidth)
        guard let upper = notesUpperBound(available: available) else { return start }
        guard translation.isFinite else { return min(start, upper) }
        let change = notesOnLeadingEdge ? translation : -translation
        return min(max(start + change, notesMinimum), upper)
    }

    private func sanitized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
