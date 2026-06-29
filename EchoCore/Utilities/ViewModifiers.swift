// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// MARK: - Custom Font Modifier

struct CustomFontModifier: ViewModifier {
    var appFont: String
    var style: Font.TextStyle
    var weight: Font.Weight = .regular

    func body(content: Content) -> some View {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 17
        case .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 17
        }

        if SettingsManager.normalizedAppFont(appFont) == SettingsManager.systemFontName {
            return AnyView(content.font(.system(style, design: .default, weight: weight)))
        } else {
            return AnyView(content.font(.custom(appFont, size: size, relativeTo: style).weight(weight)))
        }
    }
}

// MARK: - View Extensions

extension View {
    func customFont(_ style: Font.TextStyle, weight: Font.Weight = .regular, appFont: String = SettingsManager.systemFontName) -> some View {
        self.modifier(CustomFontModifier(appFont: appFont, style: style, weight: weight))
    }

    func accessibleButton(_ label: String) -> some View {
        self.accessibilityLabel(label)
    }
}

// MARK: - Sleep Timer Formatting

/// Format a remaining-seconds count for the Sleep Timer chip.
/// Uses `m:ss` while ≤ 60 minutes; falls back to `h:mm` for longer.
func sleepTimerCountdownText(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s > 3600 {
        let h = s / 3600
        let m = (s % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }
    let m = s / 60
    let sec = s % 60
    return String(format: "%d:%02d", m, sec)
}
