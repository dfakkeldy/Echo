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
        static let isHapticFeedbackEnabled = "isHapticFeedbackEnabled"
        static let watchQuickBookmarkTimeoutSeconds = "watchQuickBookmarkTimeoutSeconds"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appGroupDefaults: UserDefaults

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

    var crownAction: String { didSet { defaults.set(crownAction, forKey: Keys.crownAction) } }
    var crownVolumeSensitivity: Double { didSet { defaults.set(crownVolumeSensitivity, forKey: Keys.crownVolumeSensitivity) } }
    var crownScrubSensitivity: Double { didSet { defaults.set(crownScrubSensitivity, forKey: Keys.crownScrubSensitivity) } }
    var watchPage1: String { didSet { defaults.set(watchPage1, forKey: Keys.watchPage1) } }
    var watchPage2: String { didSet { defaults.set(watchPage2, forKey: Keys.watchPage2) } }
    var linearBarMode: String { didSet { defaults.set(linearBarMode, forKey: Keys.linearBarMode) } }
    var linearBarHidden: Bool { didSet { defaults.set(linearBarHidden, forKey: Keys.linearBarHidden) } }
    var circularRingMode: String { didSet { defaults.set(circularRingMode, forKey: Keys.circularRingMode) } }
    var circularRingHidden: Bool { didSet { defaults.set(circularRingHidden, forKey: Keys.circularRingHidden) } }
    var isHapticFeedbackEnabled: Bool { didSet { appGroupDefaults.set(isHapticFeedbackEnabled, forKey: Keys.isHapticFeedbackEnabled) } }
    var watchQuickBookmarkTimeoutSeconds: Int {
        didSet {
            let clampedValue = max(1, watchQuickBookmarkTimeoutSeconds)
            appGroupDefaults.set(clampedValue, forKey: Keys.watchQuickBookmarkTimeoutSeconds)
            if watchQuickBookmarkTimeoutSeconds != clampedValue {
                watchQuickBookmarkTimeoutSeconds = clampedValue
            }
        }
    }

    init(
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults = AppGroupDefaults.shared
    ) {
        self.defaults = defaults
        self.appGroupDefaults = appGroupDefaults

        Self.registerDefaults(defaults: defaults, appGroupDefaults: appGroupDefaults)

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
        crownAction = defaults.string(forKey: Keys.crownAction) ?? Defaults.crownAction
        crownVolumeSensitivity = defaults.double(forKey: Keys.crownVolumeSensitivity)
        crownScrubSensitivity = defaults.double(forKey: Keys.crownScrubSensitivity)
        watchPage1 = defaults.string(forKey: Keys.watchPage1) ?? Defaults.watchPage1
        watchPage2 = defaults.string(forKey: Keys.watchPage2) ?? Defaults.watchPage2
        linearBarMode = defaults.string(forKey: Keys.linearBarMode) ?? Defaults.linearBarMode
        linearBarHidden = defaults.bool(forKey: Keys.linearBarHidden)
        circularRingMode = defaults.string(forKey: Keys.circularRingMode) ?? Defaults.circularRingMode
        circularRingHidden = defaults.bool(forKey: Keys.circularRingHidden)
        isHapticFeedbackEnabled = appGroupDefaults.bool(forKey: Keys.isHapticFeedbackEnabled)
        watchQuickBookmarkTimeoutSeconds = max(
            1,
            appGroupDefaults.integer(forKey: Keys.watchQuickBookmarkTimeoutSeconds)
        )
    }

    static func registerDefaults(
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults = AppGroupDefaults.shared
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
            Keys.crownAction: Defaults.crownAction,
            Keys.crownVolumeSensitivity: Defaults.crownVolumeSensitivity,
            Keys.crownScrubSensitivity: Defaults.crownScrubSensitivity,
            Keys.watchPage1: Defaults.watchPage1,
            Keys.watchPage2: Defaults.watchPage2,
            Keys.linearBarMode: Defaults.linearBarMode,
            Keys.linearBarHidden: Defaults.linearBarHidden,
            Keys.circularRingMode: Defaults.circularRingMode,
            Keys.circularRingHidden: Defaults.circularRingHidden
        ])
        appGroupDefaults.register(defaults: [
            Keys.isHapticFeedbackEnabled: Defaults.isHapticFeedbackEnabled,
            Keys.watchQuickBookmarkTimeoutSeconds: Defaults.watchQuickBookmarkTimeoutSeconds
        ])
    }

    static func normalizedAppFont(_ appFont: String) -> String {
        appFont == legacySystemFontName ? systemFontName : appFont
    }
}
