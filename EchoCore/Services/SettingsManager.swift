import Foundation
import Observation

/// Centralized source of truth for user preference keys.
@MainActor @Observable
final class SettingsManager: SettingsManagerProtocol {
    nonisolated static let systemFontName = "System"
    nonisolated private static let legacySystemFontName = "Helvetica"

    enum Defaults {
        static let appAppearance = "System"
        static let appFont = "Lexend"
        static let themeColor = "Artwork"
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
        static let defaultPlaybackSpeed = 1.25
        static let speedPresets: [Float] = [1.0, 1.25, 1.5, 2.0, 3.0]
        static let watchPage1: [WatchAction] = [.empty, .empty, .skipBackward, .playPause, .skipForward]
        static let watchPage2: [WatchAction] = [.loopMode, .empty, .speed, .sleepTimer, .bookmark]
        static let watchPage3: [WatchAction] = [.empty, .empty, .empty, .empty, .empty]
        static let watchPage4: [WatchAction] = [.empty, .empty, .empty, .empty, .empty]
        static let watchPage5: [WatchAction] = [.empty, .empty, .empty, .empty, .empty]
        static let linearBarMode = "total"
        static let linearBarHidden = false
        static let circularRingMode = "chapter"
        static let circularRingHidden = false
        static let watchArtworkLayout = "immersive"
        static let watchBackgroundStyle = "artwork"
        static let watchTitleScrollEnabled = false
        static let watchTitleScrollSpeed = 30.0
        static let isHapticFeedbackEnabled = true
        static let watchQuickBookmarkTimeoutSeconds = 5
        static let watchDateEnabled = true
        static let watchDateFormat = "auto"
        static let truncateChapterNamesEnabled = false
        static let silenceDetectionLookbackSeconds = 10.0
        static let phonePage: [WatchAction] = [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]
        static let phoneLongPressPage: [WatchAction] = [.empty, .empty, .empty, .empty, .empty]
        static let volumeBoostGain: Float = 9.0
        static let seekBackwardDuration = 30
        static let seekForwardDuration = 30
        static let playerLayoutStyle = "default"
        static let readerFontSize: Double = 17.0
        static let readerLineSpacing: Double = 1.4
        static let readerCardTint: String = "#F5F0E8"
        static let autoAlignmentEnabled = true
        static let autoAlignmentModelSize = "base.en"
        static let autoAlignmentChapterSnapEnabled = true
        static let autoAlignmentDriftDetectionEnabled = true
        static let autoAlignmentDriftRepairEnabled = true
        static let continuousAutoAlignmentEnabled = false
    }

    private enum Keys {
        static let appAppearance = "appAppearance"
        static let appFont = "appFont"
        static let themeColor = "themeColor"
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
        static let defaultPlaybackSpeed = "defaultPlaybackSpeed"
        static let watchPage1 = "watchPage1"
        static let watchPage2 = "watchPage2"
        static let watchPage3 = "watchPage3"
        static let watchPage4 = "watchPage4"
        static let watchPage5 = "watchPage5"
        static let linearBarMode = "linearBarMode"
        static let linearBarHidden = "linearBarHidden"
        static let circularRingMode = "circularRingMode"
        static let circularRingHidden = "circularRingHidden"
        static let watchArtworkLayout = "watchArtworkLayout"
        static let watchBackgroundStyle = "watchBackgroundStyle"
        static let watchTitleScrollEnabled = "watchTitleScrollEnabled"
        static let watchTitleScrollSpeed = "watchTitleScrollSpeed"
        static let isHapticFeedbackEnabled = "isHapticFeedbackEnabled"
        static let volumeBoostGain = "volumeBoostGain"
        static let watchQuickBookmarkTimeoutSeconds = "watchQuickBookmarkTimeoutSeconds"
        static let watchDateEnabled = "watchDateEnabled"
        static let watchDateFormat = "watchDateFormat"
        static let truncateChapterNamesEnabled = "truncateChapterNamesEnabled"
        static let silenceDetectionLookbackSeconds = "silenceDetectionLookbackSeconds"
        static let phonePage = "phonePage"
        static let phoneLongPressPage = "phoneLongPressPage"
        static let seekBackwardDuration = "seekBackwardDuration"
        static let seekForwardDuration = "seekForwardDuration"
        static let watchPresets = "watchPresets"
        static let phonePresets = "phonePresets"
        static let playerLayoutStyle = "playerLayoutStyle"
        static let readerFontSize = "readerFontSize"
        static let readerLineSpacing = "readerLineSpacing"
        static let readerCardTint = "readerCardTint"
        static let autoAlignmentEnabled = "autoAlignmentEnabled"
        static let autoAlignmentModelSize = "autoAlignmentModelSize"
        static let autoAlignmentChapterSnapEnabled = "autoAlignmentChapterSnapEnabled"
        static let autoAlignmentDriftDetectionEnabled = "autoAlignmentDriftDetectionEnabled"
        static let autoAlignmentDriftRepairEnabled = "autoAlignmentDriftRepairEnabled"
        static let continuousAutoAlignmentEnabled = "continuousAutoAlignmentEnabled"
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

    var appAppearance: String { didSet { defaults.set(appAppearance, forKey: Keys.appAppearance) } }
    var appFont: String { didSet { defaults.set(appFont, forKey: Keys.appFont) } }
    var themeColor: String { didSet { defaults.set(themeColor, forKey: Keys.themeColor) } }
    var playerLayoutStyle: String { didSet { defaults.set(playerLayoutStyle, forKey: Keys.playerLayoutStyle) } }

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

    var defaultPlaybackSpeed: Double { didSet { defaults.set(defaultPlaybackSpeed, forKey: Keys.defaultPlaybackSpeed) } }
    var playBookmarksInline: Bool { didSet { defaults.set(playBookmarksInline, forKey: Keys.playBookmarksInline) } }

    // MARK: - Silence Detection

    var silenceDetectionLookbackSeconds: Double { didSet { defaults.set(silenceDetectionLookbackSeconds, forKey: Keys.silenceDetectionLookbackSeconds) } }

    // MARK: - Customizable Phone Controls & Presets
    var phonePage: [WatchAction] { didSet { defaults.set(try? JSONEncoder().encode(phonePage), forKey: Keys.phonePage) } }
    var phoneLongPressPage: [WatchAction] { didSet { defaults.set(try? JSONEncoder().encode(phoneLongPressPage), forKey: Keys.phoneLongPressPage) } }
    var seekBackwardDuration: Int { didSet { defaults.set(seekBackwardDuration, forKey: Keys.seekBackwardDuration) } }
    var seekForwardDuration: Int { didSet { defaults.set(seekForwardDuration, forKey: Keys.seekForwardDuration) } }
    var watchPresets: [WatchPreset] { didSet { defaults.set(try? JSONEncoder().encode(watchPresets), forKey: Keys.watchPresets) } }
    var phonePresets: [PhonePreset] { didSet { defaults.set(try? JSONEncoder().encode(phonePresets), forKey: Keys.phonePresets) } }

    // MARK: - Watch

    var crownAction: String { didSet { appGroupSet(crownAction, forKey: Keys.crownAction) } }
    var crownVolumeSensitivity: Double { didSet { defaults.set(crownVolumeSensitivity, forKey: Keys.crownVolumeSensitivity) } }
    var crownScrubSensitivity: Double { didSet { defaults.set(crownScrubSensitivity, forKey: Keys.crownScrubSensitivity) } }
    var watchPage1: [WatchAction] { didSet { appGroupSet(try? JSONEncoder().encode(watchPage1), forKey: Keys.watchPage1) } }
    var watchPage2: [WatchAction] { didSet { appGroupSet(try? JSONEncoder().encode(watchPage2), forKey: Keys.watchPage2) } }
    var watchPage3: [WatchAction] { didSet { appGroupSet(try? JSONEncoder().encode(watchPage3), forKey: Keys.watchPage3) } }
    var watchPage4: [WatchAction] { didSet { appGroupSet(try? JSONEncoder().encode(watchPage4), forKey: Keys.watchPage4) } }
    var watchPage5: [WatchAction] { didSet { appGroupSet(try? JSONEncoder().encode(watchPage5), forKey: Keys.watchPage5) } }
    var linearBarMode: String { didSet { appGroupSet(linearBarMode, forKey: Keys.linearBarMode) } }
    var linearBarHidden: Bool { didSet { appGroupSet(linearBarHidden, forKey: Keys.linearBarHidden) } }
    var circularRingMode: String { didSet { appGroupSet(circularRingMode, forKey: Keys.circularRingMode) } }
    var circularRingHidden: Bool { didSet { appGroupSet(circularRingHidden, forKey: Keys.circularRingHidden) } }
    var watchArtworkLayout: String { didSet { appGroupSet(watchArtworkLayout, forKey: Keys.watchArtworkLayout) } }
    var watchBackgroundStyle: String { didSet { appGroupSet(watchBackgroundStyle, forKey: Keys.watchBackgroundStyle) } }
    var watchTitleScrollEnabled: Bool { didSet { appGroupSet(watchTitleScrollEnabled, forKey: Keys.watchTitleScrollEnabled) } }
    var watchTitleScrollSpeed: Double { didSet { appGroupSet(watchTitleScrollSpeed, forKey: Keys.watchTitleScrollSpeed) } }
    var isHapticFeedbackEnabled: Bool { didSet { appGroupSet(isHapticFeedbackEnabled, forKey: Keys.isHapticFeedbackEnabled) } }
    var truncateChapterNamesEnabled: Bool { didSet { appGroupSet(truncateChapterNamesEnabled, forKey: Keys.truncateChapterNamesEnabled) } }
    var volumeBoostGain: Float { didSet { defaults.set(volumeBoostGain, forKey: Keys.volumeBoostGain) } }
    var watchDateEnabled: Bool { didSet { appGroupSet(watchDateEnabled, forKey: Keys.watchDateEnabled) } }
    var watchDateFormat: String { didSet { appGroupSet(watchDateFormat, forKey: Keys.watchDateFormat) } }

    // MARK: - Reader

    var readerFontSize: Double {
        get { defaults.double(forKey: Keys.readerFontSize).nonZero ?? Defaults.readerFontSize }
        set { defaults.set(newValue, forKey: Keys.readerFontSize) }
    }

    var readerLineSpacing: Double {
        get { defaults.double(forKey: Keys.readerLineSpacing).nonZero ?? Defaults.readerLineSpacing }
        set { defaults.set(newValue, forKey: Keys.readerLineSpacing) }
    }

    var readerCardTint: String {
        get { defaults.string(forKey: Keys.readerCardTint) ?? Defaults.readerCardTint }
        set { defaults.set(newValue, forKey: Keys.readerCardTint) }
    }

    // MARK: - Auto-Alignment

    var autoAlignmentEnabled: Bool { didSet { defaults.set(autoAlignmentEnabled, forKey: Keys.autoAlignmentEnabled) } }
    var autoAlignmentModelSize: String { didSet { defaults.set(autoAlignmentModelSize, forKey: Keys.autoAlignmentModelSize) } }
    var autoAlignmentChapterSnapEnabled: Bool { didSet { defaults.set(autoAlignmentChapterSnapEnabled, forKey: Keys.autoAlignmentChapterSnapEnabled) } }
    var autoAlignmentDriftDetectionEnabled: Bool { didSet { defaults.set(autoAlignmentDriftDetectionEnabled, forKey: Keys.autoAlignmentDriftDetectionEnabled) } }
    var autoAlignmentDriftRepairEnabled: Bool { didSet { defaults.set(autoAlignmentDriftRepairEnabled, forKey: Keys.autoAlignmentDriftRepairEnabled) } }
    var continuousAutoAlignmentEnabled: Bool { didSet { defaults.set(continuousAutoAlignmentEnabled, forKey: Keys.continuousAutoAlignmentEnabled) } }

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
            guard let d = UserDefaults(suiteName: "group.com.echo.audiobooks") else {
                assertionFailure("Unable to open app-group UserDefaults suite: group.com.echo.audiobooks")
                // Use a distinct fallback suite so watch-facing settings don't
                // leak into .standard where the Watch cannot read them.
                return UserDefaults(suiteName: "group.com.echo.audiobooks.fallback") ?? .standard
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
                (Keys.watchPage3, { defaults.object(forKey: Keys.watchPage3) }),
                (Keys.watchPage4, { defaults.object(forKey: Keys.watchPage4) }),
                (Keys.watchPage5, { defaults.object(forKey: Keys.watchPage5) }),
                (Keys.linearBarMode, { defaults.object(forKey: Keys.linearBarMode) }),
                (Keys.linearBarHidden, { defaults.object(forKey: Keys.linearBarHidden) }),
                (Keys.circularRingMode, { defaults.object(forKey: Keys.circularRingMode) }),
                (Keys.circularRingHidden, { defaults.object(forKey: Keys.circularRingHidden) }),
                (Keys.watchArtworkLayout, { defaults.object(forKey: Keys.watchArtworkLayout) }),
                (Keys.watchBackgroundStyle, { defaults.object(forKey: Keys.watchBackgroundStyle) }),
                (Keys.watchTitleScrollEnabled, { defaults.object(forKey: Keys.watchTitleScrollEnabled) }),
                (Keys.watchTitleScrollSpeed, { defaults.object(forKey: Keys.watchTitleScrollSpeed) }),
                (Keys.isHapticFeedbackEnabled, { defaults.object(forKey: Keys.isHapticFeedbackEnabled) }),
                (Keys.truncateChapterNamesEnabled, { defaults.object(forKey: Keys.truncateChapterNamesEnabled) }),
                (Keys.watchQuickBookmarkTimeoutSeconds, { defaults.object(forKey: Keys.watchQuickBookmarkTimeoutSeconds) }),
            ]
            for (key, read) in watchKeys {
                if appGroupDefaults.object(forKey: key) == nil, let value = read() {
                    appGroupDefaults.set(value, forKey: key)
                }
            }
            appGroupDefaults.set(true, forKey: "didMigrateWatchSettingsToAppGroup_v2")
        }

        if defaults.object(forKey: "isDarkMode") != nil {
            let dark = defaults.bool(forKey: "isDarkMode")
            if defaults.object(forKey: Keys.appAppearance) == nil {
                let migrated = dark ? "Dark" : "Light"
                appAppearance = migrated
                defaults.set(migrated, forKey: Keys.appAppearance)
            } else {
                appAppearance = defaults.string(forKey: Keys.appAppearance) ?? Defaults.appAppearance
            }
            defaults.removeObject(forKey: "isDarkMode")
        } else {
            appAppearance = defaults.string(forKey: Keys.appAppearance) ?? Defaults.appAppearance
        }
        
        let storedAppFont = defaults.string(forKey: Keys.appFont) ?? Defaults.appFont
        let normalizedAppFont = Self.normalizedAppFont(storedAppFont)
        appFont = normalizedAppFont
        if normalizedAppFont != storedAppFont {
            defaults.set(normalizedAppFont, forKey: Keys.appFont)
        }
        themeColor = defaults.string(forKey: Keys.themeColor) ?? Defaults.themeColor
        playerLayoutStyle = defaults.string(forKey: Keys.playerLayoutStyle) ?? Defaults.playerLayoutStyle
        isRewindEnabled = defaults.bool(forKey: Keys.isRewindEnabled)
        rewindPauseSecondsThreshold = defaults.integer(forKey: Keys.rewindPauseSecondsThreshold)
        rewindAmountAfterSeconds = defaults.integer(forKey: Keys.rewindAmountAfterSeconds)
        rewindPauseMinutesThreshold = defaults.integer(forKey: Keys.rewindPauseMinutesThreshold)
        rewindAmountAfterMinutes = defaults.integer(forKey: Keys.rewindAmountAfterMinutes)
        rewindPauseHoursThreshold = defaults.integer(forKey: Keys.rewindPauseHoursThreshold)
        rewindAmountAfterHours = defaults.integer(forKey: Keys.rewindAmountAfterHours)
        rewindHoursToChapterStart = defaults.bool(forKey: Keys.rewindHoursToChapterStart)
        defaultPlaybackSpeed = defaults.object(forKey: Keys.defaultPlaybackSpeed) as? Double ?? Defaults.defaultPlaybackSpeed
        playBookmarksInline = defaults.bool(forKey: Keys.playBookmarksInline)
        silenceDetectionLookbackSeconds = defaults.double(forKey: Keys.silenceDetectionLookbackSeconds)
        crownAction = appGroupDefaults.string(forKey: Keys.crownAction) ?? Defaults.crownAction
        crownVolumeSensitivity = defaults.double(forKey: Keys.crownVolumeSensitivity)
        crownScrubSensitivity = defaults.double(forKey: Keys.crownScrubSensitivity)
        watchPage1 = Self.decodeWatchPage(key: Keys.watchPage1, from: appGroupDefaults, fallback: Defaults.watchPage1)
        watchPage2 = Self.decodeWatchPage(key: Keys.watchPage2, from: appGroupDefaults, fallback: Defaults.watchPage2)
        watchPage3 = Self.decodeWatchPage(key: Keys.watchPage3, from: appGroupDefaults, fallback: Defaults.watchPage3)
        watchPage4 = Self.decodeWatchPage(key: Keys.watchPage4, from: appGroupDefaults, fallback: Defaults.watchPage4)
        watchPage5 = Self.decodeWatchPage(key: Keys.watchPage5, from: appGroupDefaults, fallback: Defaults.watchPage5)
        linearBarMode = appGroupDefaults.string(forKey: Keys.linearBarMode) ?? Defaults.linearBarMode
        linearBarHidden = appGroupDefaults.bool(forKey: Keys.linearBarHidden)
        circularRingMode = appGroupDefaults.string(forKey: Keys.circularRingMode) ?? Defaults.circularRingMode
        circularRingHidden = appGroupDefaults.bool(forKey: Keys.circularRingHidden)
        watchArtworkLayout = appGroupDefaults.string(forKey: Keys.watchArtworkLayout) ?? Defaults.watchArtworkLayout
        watchBackgroundStyle = appGroupDefaults.string(forKey: Keys.watchBackgroundStyle) ?? Defaults.watchBackgroundStyle
        watchTitleScrollEnabled = appGroupDefaults.bool(forKey: Keys.watchTitleScrollEnabled)
        if let storedSpeed = appGroupDefaults.object(forKey: Keys.watchTitleScrollSpeed) as? Double {
            watchTitleScrollSpeed = storedSpeed
        } else {
            watchTitleScrollSpeed = Defaults.watchTitleScrollSpeed
        }
        isHapticFeedbackEnabled = appGroupDefaults.bool(forKey: Keys.isHapticFeedbackEnabled)
        truncateChapterNamesEnabled = appGroupDefaults.bool(forKey: Keys.truncateChapterNamesEnabled)
        volumeBoostGain = defaults.object(forKey: Keys.volumeBoostGain) as? Float ?? Defaults.volumeBoostGain
        watchQuickBookmarkTimeoutSeconds = max(
            1,
            appGroupDefaults.integer(forKey: Keys.watchQuickBookmarkTimeoutSeconds)
        )
        watchDateEnabled = appGroupDefaults.object(forKey: Keys.watchDateEnabled) as? Bool ?? Defaults.watchDateEnabled
        watchDateFormat = appGroupDefaults.string(forKey: Keys.watchDateFormat) ?? Defaults.watchDateFormat
        phonePage = Self.decodeWatchPage(key: Keys.phonePage, from: defaults, fallback: Defaults.phonePage)
        phoneLongPressPage = Self.decodeWatchPage(key: Keys.phoneLongPressPage, from: defaults, fallback: Defaults.phoneLongPressPage)
        
        let storedSeekBackward = defaults.integer(forKey: Keys.seekBackwardDuration)
        seekBackwardDuration = storedSeekBackward == 0 ? Defaults.seekBackwardDuration : storedSeekBackward
        
        let storedSeekForward = defaults.integer(forKey: Keys.seekForwardDuration)
        seekForwardDuration = storedSeekForward == 0 ? Defaults.seekForwardDuration : storedSeekForward
        
        if let presetsData = defaults.data(forKey: Keys.watchPresets),
           let decoded = try? JSONDecoder().decode([WatchPreset].self, from: presetsData) {
            watchPresets = decoded
        } else {
            watchPresets = []
        }
        
        if let presetsData = defaults.data(forKey: Keys.phonePresets),
           let decoded = try? JSONDecoder().decode([PhonePreset].self, from: presetsData) {
            phonePresets = decoded
        } else {
            phonePresets = []
        }

        autoAlignmentEnabled = defaults.object(forKey: Keys.autoAlignmentEnabled) as? Bool ?? Defaults.autoAlignmentEnabled
        autoAlignmentModelSize = defaults.string(forKey: Keys.autoAlignmentModelSize) ?? Defaults.autoAlignmentModelSize
        autoAlignmentChapterSnapEnabled = defaults.object(forKey: Keys.autoAlignmentChapterSnapEnabled) as? Bool ?? Defaults.autoAlignmentChapterSnapEnabled
        autoAlignmentDriftDetectionEnabled = defaults.object(forKey: Keys.autoAlignmentDriftDetectionEnabled) as? Bool ?? Defaults.autoAlignmentDriftDetectionEnabled
        autoAlignmentDriftRepairEnabled = defaults.object(forKey: Keys.autoAlignmentDriftRepairEnabled) as? Bool ?? Defaults.autoAlignmentDriftRepairEnabled
        continuousAutoAlignmentEnabled = defaults.object(forKey: Keys.continuousAutoAlignmentEnabled) as? Bool ?? Defaults.continuousAutoAlignmentEnabled
    }

    static func registerDefaults(
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults = {
            guard let d = UserDefaults(suiteName: "group.com.echo.audiobooks") else {
                assertionFailure("Unable to open app-group UserDefaults suite: group.com.echo.audiobooks")
                return UserDefaults(suiteName: "group.com.echo.audiobooks.fallback") ?? .standard
            }
            return d
        }()
    ) {
        defaults.register(defaults: [
            Keys.appAppearance: Defaults.appAppearance,
            Keys.appFont: Defaults.appFont,
            Keys.themeColor: Defaults.themeColor,
            Keys.isRewindEnabled: Defaults.isRewindEnabled,
            Keys.rewindPauseSecondsThreshold: Defaults.rewindPauseSecondsThreshold,
            Keys.rewindAmountAfterSeconds: Defaults.rewindAmountAfterSeconds,
            Keys.rewindPauseMinutesThreshold: Defaults.rewindPauseMinutesThreshold,
            Keys.rewindAmountAfterMinutes: Defaults.rewindAmountAfterMinutes,
            Keys.rewindPauseHoursThreshold: Defaults.rewindPauseHoursThreshold,
            Keys.rewindAmountAfterHours: Defaults.rewindAmountAfterHours,
            Keys.rewindHoursToChapterStart: Defaults.rewindHoursToChapterStart,
            Keys.defaultPlaybackSpeed: Defaults.defaultPlaybackSpeed,
            Keys.playBookmarksInline: Defaults.playBookmarksInline,
            Keys.silenceDetectionLookbackSeconds: Defaults.silenceDetectionLookbackSeconds,
            Keys.crownVolumeSensitivity: Defaults.crownVolumeSensitivity,
            Keys.crownScrubSensitivity: Defaults.crownScrubSensitivity,
            Keys.phonePage: (try? JSONEncoder().encode(Defaults.phonePage)) ?? Data(),
            Keys.phoneLongPressPage: (try? JSONEncoder().encode(Defaults.phoneLongPressPage)) ?? Data(),
            Keys.seekBackwardDuration: Defaults.seekBackwardDuration,
            Keys.seekForwardDuration: Defaults.seekForwardDuration,
            Keys.playerLayoutStyle: Defaults.playerLayoutStyle,
            Keys.readerFontSize: Defaults.readerFontSize,
            Keys.readerLineSpacing: Defaults.readerLineSpacing,
            Keys.readerCardTint: Defaults.readerCardTint,
            Keys.autoAlignmentEnabled: Defaults.autoAlignmentEnabled,
            Keys.autoAlignmentModelSize: Defaults.autoAlignmentModelSize,
            Keys.autoAlignmentChapterSnapEnabled: Defaults.autoAlignmentChapterSnapEnabled,
            Keys.autoAlignmentDriftDetectionEnabled: Defaults.autoAlignmentDriftDetectionEnabled,
            Keys.autoAlignmentDriftRepairEnabled: Defaults.autoAlignmentDriftRepairEnabled,
            Keys.continuousAutoAlignmentEnabled: Defaults.continuousAutoAlignmentEnabled,
        ])
        appGroupDefaults.register(defaults: [
            Keys.crownAction: Defaults.crownAction,
            Keys.watchPage1: (try? JSONEncoder().encode(Defaults.watchPage1)) ?? Data(),
            Keys.watchPage2: (try? JSONEncoder().encode(Defaults.watchPage2)) ?? Data(),
            Keys.watchPage3: (try? JSONEncoder().encode(Defaults.watchPage3)) ?? Data(),
            Keys.watchPage4: (try? JSONEncoder().encode(Defaults.watchPage4)) ?? Data(),
            Keys.watchPage5: (try? JSONEncoder().encode(Defaults.watchPage5)) ?? Data(),
            Keys.linearBarMode: Defaults.linearBarMode,
            Keys.linearBarHidden: Defaults.linearBarHidden,
            Keys.circularRingMode: Defaults.circularRingMode,
            Keys.circularRingHidden: Defaults.circularRingHidden,
            Keys.watchArtworkLayout: Defaults.watchArtworkLayout,
            Keys.watchBackgroundStyle: Defaults.watchBackgroundStyle,
            Keys.watchTitleScrollEnabled: Defaults.watchTitleScrollEnabled,
            Keys.watchTitleScrollSpeed: Defaults.watchTitleScrollSpeed,
            Keys.isHapticFeedbackEnabled: Defaults.isHapticFeedbackEnabled,
            Keys.truncateChapterNamesEnabled: Defaults.truncateChapterNamesEnabled,
            Keys.volumeBoostGain: Defaults.volumeBoostGain,
            Keys.watchQuickBookmarkTimeoutSeconds: Defaults.watchQuickBookmarkTimeoutSeconds,
            Keys.watchDateEnabled: Defaults.watchDateEnabled,
            Keys.watchDateFormat: Defaults.watchDateFormat
        ])
    }

    /// Decodes `[WatchAction]` from JSON. Falls back to the old comma-separated
    /// string format for transparent one-time migration.
    private static func decodeWatchPage(key: String, from defaults: UserDefaults, fallback: [WatchAction]) -> [WatchAction] {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WatchAction].self, from: data) {
            return decoded
        }
        // Migration from old comma-separated string format
        if let oldString = defaults.string(forKey: key) {
            let parsed = oldString.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
            var padded = Array(parsed.prefix(5))
            while padded.count < 5 { padded.append(.empty) }
            if let encoded = try? JSONEncoder().encode(padded) {
                defaults.set(encoded, forKey: key)
            }
            return padded
        }
        return fallback
    }

    static func normalizedAppFont(_ appFont: String) -> String {
        appFont == legacySystemFontName ? systemFontName : appFont
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
