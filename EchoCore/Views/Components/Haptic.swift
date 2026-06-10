import UIKit

/// Gated haptic feedback utility — respects the user's haptic preference.
/// Call `Haptic.play(.light)` instead of creating `UIImpactFeedbackGenerator` directly.
enum Haptic {
    /// Whether haptic feedback is enabled per user preference.
    static var isEnabled: Bool {
        UserDefaults(suiteName: "group.com.echo.audiobooks")?
            .object(forKey: "isHapticFeedbackEnabled") as? Bool ?? true
    }

    static func play(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
