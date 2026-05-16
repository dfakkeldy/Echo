import Foundation
import Observation

/// Centralized source of truth for user preference keys.
@Observable
final class SettingsManager {
    static let systemFontName = "System"
    private static let legacySystemFontName = "Helvetica"

    enum Defaults {
        static let isDarkMode = true
        static let appFont = "Lexend"
        static let isRewindEnabled = false
        static let rewindPauseSecondsThreshold = 30
        static let rewindAmountAfterSeconds = 10
        static let rewindPauseMinutesThreshold = 5
        static let rewindAmountAfterMinutes = 30
        static let rewindPauseHoursThreshold = 1
        static let rewindAmountAfterHours = 90
        static let rewindHoursToChapterStart = false
        static let playBookmarksInline = true
        static let crownAction = "volume"
        static let crownVolumeSensitivity = 0.05
        static let crownScrubSensitivity = 0.5
        static let watchPage1 = "empty,empty,skipBackward,playPause,skipForward"
        static let watchPage2 = "loopMode,empty,speed,sleepTimer,bookmark"
        static let linearBarMode = "total"
        static let linearBarHidden = false
        static let circularRingMode = "chapter"
        static let circularRingHidden = false
        static let watchArtworkLayout = "immersive"
        static let watchBackgroundStyle = "artwork"
        static let isHapticFeedbackEnabled = true
        static let watchQuickBookmarkTimeoutSeconds = 5
    }

    private enum Keys {
        static let isDarkMode = "isDarkMode"
        static let appFont = "appFont"
        static let isRewindEnabled = "isRewindEnabled"
        static let rewindPauseSecondsThreshold = "rewindPauseSecondsThreshold"
        static let rewindAmountAfterSeconds = "rewindAmountAfterSeconds"
        static let rewindPauseMinutesThreshold = "rewindPauseMinutesThreshold"
        static let rewindAmountAfterMinutes = "rewindAmountAfterMinutes"
        static let rewindPauseHoursThreshold = "rewindPauseHoursThreshold"
        static let rewindAmountAfterHours = "rewindAmountAfterHours"
        static let rewindHoursToChapterStart = "rewindHoursToChapterStart"
        static let playBookmarksInline = "playBookmarksInline"
        static let crownAction = "crownAction"
        static let crownVolumeSensitivity = "crownVolumeSensitivity"
        static let crownScrubSensitivity = "crownScrubSensitivity"
        static let watchPage1 = "watchPage1"
        static let watchPage2 = "watchPage2"
        static let linearBarMode = "linearBarMode"
        static let linearBarHidden = "linearBarHidden"
        static let circularRingMode = "circularRingMode"
        static let circularRingHidden = "circularRingHidden"
        static let watchArtworkLayout = "watchArtworkLayout"
        static let watchBackgroundStyle = "watchBackgroundStyle"
        static let isHapticFeedbackEnabled = "isHapticFeedbackEnabled"
        static let watchQuickBookmarkTimeoutSeconds = "watchQuickBookmarkTimeoutSeconds"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appGroupDefaults: UserDefaults
    @ObservationIgnored private let isAppGroupAvailable: Bool

    /// Guards watch-facing writes so settings don't silently land in `.standard`
    /// when the App Group suite is unavailable (Watch cannot read standard defaults).
    private func appGroupSet(_ value: Any?, forKey key: String) {
        guard isAppGroupAvailable else { return }
        appGroupDefaults.set(value, forKey: key)
    }

    // MARK: - Appearance

    var isDarkMode: Bool { didSet { defaults.set(isDarkMode, forKey: Keys.isDarkMode) } }
    var appFont: String { didSet { defaults.set(appFont, forKey: Keys.appFont) } }

    // MARK: - Smart Rewind

    var isRewindEnabled: Bool { didSet { defaults.set(isRewindEnabled, forKey: Keys.isRewindEnabled) } }
    var rewindPauseSecondsThreshold: Int { didSet { defaults.set(rewindPauseSecondsThreshold, forKey: Keys.rewindPauseSecondsThreshold) } }
    var rewindAmountAfterSeconds: Int { didSet { defaults.set(rewindAmountAfterSeconds, forKey: Keys.rewindAmountAfterSeconds) } }
    var rewindPauseMinutesThreshold: Int { didSet { defaults.set(rewindPauseMinutesThreshold, forKey: Keys.rewindPauseMinutesThreshold) } }
    var rewindAmountAfterMinutes: Int { didSet { defaults.set(rewindAmountAfterMinutes, forKey: Keys.rewindAmountAfterMinutes) } }
    var rewindPauseHoursThreshold: Int { didSet { defaults.set(rewindPauseHoursThreshold, forKey: Keys.rewindPauseHoursThreshold) } }
    var rewindAmountAfterHours: Int { didSet { defaults.set(rewindAmountAfterHours, forKey: Keys.rewindAmountAfterHours) } }
    var rewindHoursToChapterStart: Bool { didSet { defaults.set(rewindHoursToChapterStart, forKey: Keys.rewindHoursToChapterStart) } }

    // MARK: - Playback

    var playBookmarksInline: Bool { didSet { defaults.set(playBookmarksInline, forKey: Keys.playBookmarksInline) } }

    // MARK: - Watch

    var crownAction: String { didSet { appGroupSet(crownAction, forKey: Keys.crownAction) } }
    var crownVolumeSensitivity: Double { didSet { defaults.set(crownVolumeSensitivity, forKey: Keys.crownVolumeSensitivity) } }
    var crownScrubSensitivity: Double { didSet { defaults.set(crownScrubSensitivity, forKey: Keys.crownScrubSensitivity) } }
    var watchPage1: String { didSet { appGroupSet(watchPage1, forKey: Keys.watchPage1) } }
    var watchPage2: String { didSet { appGroupSet(watchPage2, forKey: Keys.watchPage2) } }
    var linearBarMode: String { didSet { appGroupSet(linearBarMode, forKey: Keys.linearBarMode) } }
    var linearBarHidden: Bool { didSet { appGroupSet(linearBarHidden, forKey: Keys.linearBarHidden) } }
    var circularRingMode: String { didSet { appGroupSet(circularRingMode, forKey: Keys.circularRingMode) } }
    var circularRingHidden: Bool { didSet { appGroupSet(circularRingHidden, forKey: Keys.circularRingHidden) } }
    var watchArtworkLayout: String { didSet { appGroupSet(watchArtworkLayout, forKey: Keys.watchArtworkLayout) } }
    var watchBackgroundStyle: String { didSet { appGroupSet(watchBackgroundStyle, forKey: Keys.watchBackgroundStyle) } }
    var isHapticFeedbackEnabled: Bool { didSet { appGroupSet(isHapticFeedbackEnabled, forKey: Keys.isHapticFeedbackEnabled) } }
    var watchQuickBookmarkTimeoutSeconds: Int {
        didSet {
            let clampedValue = max(1, watchQuickBookmarkTimeoutSeconds)
            appGroupSet(clampedValue, forKey: Keys.watchQuickBookmarkTimeoutSeconds)
            if watchQuickBookmarkTimeoutSeconds != clampedValue {
                watchQuickBookmarkTimeoutSeconds = clampedValue
            }
        }
    }

    init(
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults = {
            guard let d = UserDefaults(suiteName: "group.com.orbitaudiobooks") else {
                assertionFailure("Unable to open app-group UserDefaults suite: group.com.orbitaudiobooks")
                // Use a distinct fallback suite so watch-facing settings don't
                // leak into .standard where the Watch cannot read them.
                return UserDefaults(suiteName: "group.com.orbitaudiobooks.fallback") ?? .standard
            }
            return d
        }()
    ) {
        self.defaults = defaults
        self.appGroupDefaults = appGroupDefaults
        self.isAppGroupAvailable = appGroupDefaults != defaults

        Self.registerDefaults(defaults: defaults, appGroupDefaults: appGroupDefaults)

        // One-time migration: copy watch-facing settings from standard defaults
        // to the App Group suite so the Watch and Widget can read them directly.
        if isAppGroupAvailable,
           !appGroupDefaults.bool(forKey: "didMigrateWatchSettingsToAppGroup_v2") {
            let watchKeys: [(String, () -> Any?)] = [
                (Keys.crownAction, { defaults.object(forKey: Keys.crownAction) }),
                (Keys.watchPage1, { defaults.object(forKey: Keys.watchPage1) }),
                (Keys.watchPage2, { defaults.object(forKey: Keys.watchPage2) }),
                (Keys.linearBarMode, { defaults.object(forKey: Keys.linearBarMode) }),
                (Keys.linearBarHidden, { defaults.object(forKey: Keys.linearBarHidden) }),
                (Keys.circularRingMode, { defaults.object(forKey: Keys.circularRingMode) }),
                (Keys.circularRingHidden, { defaults.object(forKey: Keys.circularRingHidden) }),
                (Keys.watchArtworkLayout, { defaults.object(forKey: Keys.watchArtworkLayout) }),
                (Keys.watchBackgroundStyle, { defaults.object(forKey: Keys.watchBackgroundStyle) }),
                (Keys.isHapticFeedbackEnabled, { defaults.object(forKey: Keys.isHapticFeedbackEnabled) }),
                (Keys.watchQuickBookmarkTimeoutSeconds, { defaults.object(forKey: Keys.watchQuickBookmarkTimeoutSeconds) }),
            ]
            for (key, read) in watchKeys {
                if appGroupDefaults.object(forKey: key) == nil, let value = read() {
                    appGroupDefaults.set(value, forKey: key)
                }
            }
            appGroupDefaults.set(true, forKey: "didMigrateWatchSettingsToAppGroup_v2")
        }

        isDarkMode = defaults.bool(forKey: Keys.isDarkMode)
        let storedAppFont = defaults.string(forKey: Keys.appFont) ?? Defaults.appFont
        let normalizedAppFont = Self.normalizedAppFont(storedAppFont)
        appFont = normalizedAppFont
        if normalizedAppFont != storedAppFont {
            defaults.set(normalizedAppFont, forKey: Keys.appFont)
        }
        isRewindEnabled = defaults.bool(forKey: Keys.isRewindEnabled)
        rewindPauseSecondsThreshold = defaults.integer(forKey: Keys.rewindPauseSecondsThreshold)
        rewindAmountAfterSeconds = defaults.integer(forKey: Keys.rewindAmountAfterSeconds)
        rewindPauseMinutesThreshold = defaults.integer(forKey: Keys.rewindPauseMinutesThreshold)
        rewindAmountAfterMinutes = defaults.integer(forKey: Keys.rewindAmountAfterMinutes)
        rewindPauseHoursThreshold = defaults.integer(forKey: Keys.rewindPauseHoursThreshold)
        rewindAmountAfterHours = defaults.integer(forKey: Keys.rewindAmountAfterHours)
        rewindHoursToChapterStart = defaults.bool(forKey: Keys.rewindHoursToChapterStart)
        playBookmarksInline = defaults.bool(forKey: Keys.playBookmarksInline)
        crownAction = appGroupDefaults.string(forKey: Keys.crownAction) ?? Defaults.crownAction
        crownVolumeSensitivity = defaults.double(forKey: Keys.crownVolumeSensitivity)
        crownScrubSensitivity = defaults.double(forKey: Keys.crownScrubSensitivity)
        watchPage1 = appGroupDefaults.string(forKey: Keys.watchPage1) ?? Defaults.watchPage1
        watchPage2 = appGroupDefaults.string(forKey: Keys.watchPage2) ?? Defaults.watchPage2
        linearBarMode = appGroupDefaults.string(forKey: Keys.linearBarMode) ?? Defaults.linearBarMode
        linearBarHidden = appGroupDefaults.bool(forKey: Keys.linearBarHidden)
        circularRingMode = appGroupDefaults.string(forKey: Keys.circularRingMode) ?? Defaults.circularRingMode
        circularRingHidden = appGroupDefaults.bool(forKey: Keys.circularRingHidden)
        watchArtworkLayout = appGroupDefaults.string(forKey: Keys.watchArtworkLayout) ?? Defaults.watchArtworkLayout
        watchBackgroundStyle = appGroupDefaults.string(forKey: Keys.watchBackgroundStyle) ?? Defaults.watchBackgroundStyle
        isHapticFeedbackEnabled = appGroupDefaults.bool(forKey: Keys.isHapticFeedbackEnabled)
        watchQuickBookmarkTimeoutSeconds = max(
            1,
            appGroupDefaults.integer(forKey: Keys.watchQuickBookmarkTimeoutSeconds)
        )
    }

    static func registerDefaults(
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults = {
            guard let d = UserDefaults(suiteName: "group.com.orbitaudiobooks") else {
                assertionFailure("Unable to open app-group UserDefaults suite: group.com.orbitaudiobooks")
                return UserDefaults(suiteName: "group.com.orbitaudiobooks.fallback") ?? .standard
            }
            return d
        }()
    ) {
        defaults.register(defaults: [
            Keys.isDarkMode: Defaults.isDarkMode,
            Keys.appFont: Defaults.appFont,
            Keys.isRewindEnabled: Defaults.isRewindEnabled,
            Keys.rewindPauseSecondsThreshold: Defaults.rewindPauseSecondsThreshold,
            Keys.rewindAmountAfterSeconds: Defaults.rewindAmountAfterSeconds,
            Keys.rewindPauseMinutesThreshold: Defaults.rewindPauseMinutesThreshold,
            Keys.rewindAmountAfterMinutes: Defaults.rewindAmountAfterMinutes,
            Keys.rewindPauseHoursThreshold: Defaults.rewindPauseHoursThreshold,
            Keys.rewindAmountAfterHours: Defaults.rewindAmountAfterHours,
            Keys.rewindHoursToChapterStart: Defaults.rewindHoursToChapterStart,
            Keys.playBookmarksInline: Defaults.playBookmarksInline,
            Keys.crownVolumeSensitivity: Defaults.crownVolumeSensitivity,
            Keys.crownScrubSensitivity: Defaults.crownScrubSensitivity
        ])
        appGroupDefaults.register(defaults: [
            Keys.crownAction: Defaults.crownAction,
            Keys.watchPage1: Defaults.watchPage1,
            Keys.watchPage2: Defaults.watchPage2,
            Keys.linearBarMode: Defaults.linearBarMode,
            Keys.linearBarHidden: Defaults.linearBarHidden,
            Keys.circularRingMode: Defaults.circularRingMode,
            Keys.circularRingHidden: Defaults.circularRingHidden,
            Keys.watchArtworkLayout: Defaults.watchArtworkLayout,
            Keys.watchBackgroundStyle: Defaults.watchBackgroundStyle,
            Keys.isHapticFeedbackEnabled: Defaults.isHapticFeedbackEnabled,
            Keys.watchQuickBookmarkTimeoutSeconds: Defaults.watchQuickBookmarkTimeoutSeconds
        ])
    }

    static func normalizedAppFont(_ appFont: String) -> String {
        appFont == legacySystemFontName ? systemFontName : appFont
    }
}
