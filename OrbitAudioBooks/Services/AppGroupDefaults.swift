import Foundation

/// Shared app-group defaults used by both the iOS app and the Watch companion
/// to synchronize preferences and user settings across targets.
enum AppGroupDefaults {
    /// The app-group suite name registered in the app's entitlements.
    static let suiteName = "group.com.orbitaudiobooks"

    /// The shared `UserDefaults` instance backed by the app-group suite,
    /// falling back to `.standard` if the suite is unavailable.
    static var shared: UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            #if DEBUG
            assertionFailure("Unable to open app-group UserDefaults suite: \(suiteName)")
            #endif
            return .standard
        }
        return defaults
    }

    /// Whether haptic feedback is enabled for Watch interactions.
    /// Defaults to `true`.
    static var isHapticFeedbackEnabled: Bool {
        get { shared.object(forKey: "isHapticFeedbackEnabled") as? Bool ?? true }
        set { shared.set(newValue, forKey: "isHapticFeedbackEnabled") }
    }

    /// The timeout in seconds the Watch uses before auto-committing a
    /// quick-bookmark gesture. Clamped to a minimum of 1 second.
    /// Defaults to `5`.
    static var watchQuickBookmarkTimeoutSeconds: Int {
        get { shared.object(forKey: "watchQuickBookmarkTimeoutSeconds") as? Int ?? 5 }
        set { shared.set(max(1, newValue), forKey: "watchQuickBookmarkTimeoutSeconds") }
    }
}
