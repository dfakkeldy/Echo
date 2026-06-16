// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The app-wide accent-color choices surfaced in Settings → Appearance → Accent
/// Color. `.system` defers to the OS tint; `.artwork` is resolved dynamically
/// from the loaded book's cover (see `PlayerModel.resolvedThemeTint`).
enum ThemeColor: String, CaseIterable, Identifiable {
    case artwork = "Artwork"
    case system = "System"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case mint = "Mint"
    case teal = "Teal"
    case cyan = "Cyan"
    case indigo = "Indigo"

    var id: String { self.rawValue }

    /// Returns the static colour for this theme, or `nil` for `.system`
    /// (use OS default) and `.artwork` (use dynamic colour from cover).
    var color: Color? {
        switch self {
        case .artwork: return nil
        case .system: return nil
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .indigo: return .indigo
        }
    }
}
