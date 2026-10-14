// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Registers a shortcut only while its page owns the primary action.
struct WatchPrimaryActionModifier: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        // TabView retains neighboring pages. Insert/remove the registration
        // when selection changes instead of keeping disabled shortcuts in
        // those cached pages. Keep this modifier on the button so changing
        // ownership preserves the page's state (including flashcard progress).
        if isActive {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}
