// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Navigation scaffold for a sheet presented from the player, washed in the
/// current cover's tonal ramp so it continues the room the player is already
/// in instead of flashing to systemBackground.
///
/// The scaffold owns the `NavigationStack` deliberately. A stack's
/// `UINavigationController` paints an opaque systemBackground of its own, so a
/// ramp layered BEHIND the stack is invisible — the bug that left the whole
/// player looking untinted until PR #420. By owning the stack, this type makes
/// that layering unreproducible at the call site: callers hand over content,
/// and the wash always lands inside.
///
/// Scope is chrome only. The tab bar, the Library grid, and long-form reading
/// surfaces stay system-neutral: the wash means "you are inside this book", and
/// painting it everywhere would say nothing.
///
/// The accent needs no wiring here. The app root already tints from
/// `PlayerModel.resolvedThemeTint`, which sheets inherit through the
/// environment, and that honours a user-chosen static theme colour rather than
/// overriding it with the cover's.
struct CoverThemedSheet<Content: View>: View {
    let theme: CoverTheme
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ZStack {
                ramp
                content
                    // A Form/List paints its own grouped canvas over anything
                    // behind it; hiding it lets the ramp through, and the row
                    // cards stay system-coloured so their contents keep their
                    // guaranteed legibility.
                    .scrollContentBackground(.hidden)
            }
            // Without this the bar keeps its own opaque material and reads as a
            // grey band laid across the top of the wash.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        }
        // A sheet has TWO opaque layers to defeat, not one. The ZStack above
        // handles the navigation stack's own systemBackground; this handles the
        // presentation backdrop underneath it, which is what actually showed
        // through when only the in-stack ramp was applied (measured #1C1C1E —
        // systemBackground exactly). Harmless outside a sheet.
        .presentationBackground { ramp }
    }

    private var ramp: some View {
        LinearGradient(
            colors: [theme.backgroundTop, theme.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// Opening heights for short book sheets, so each sheet ends where its content
/// ends instead of leaving an empty floor (council round 4). `.large` stays in
/// every detent set, so content that grows or scrolls can still be pulled up.
enum CoverSheetFit {
    /// Grabber, inline title bar and the inset-grouped list's top inset.
    static let listChrome: CGFloat = 106
    /// Breathing room under the last card.
    static let bottomMargin: CGFloat = 20
    /// A fitted list taller than this opens at `.medium`, as before: about
    /// half an iPhone screen, so a long list never opens nearly full height.
    static let maxFittedHeight: CGFloat = 440

    /// The opening detent for an inset-grouped list of `rows` rows.
    static func listDetent(rows: Int, rowHeight: CGFloat) -> PresentationDetent {
        let height = listChrome + CGFloat(max(rows, 1)) * rowHeight + bottomMargin
        return height <= maxFittedHeight ? .height(height) : .medium
    }
}
