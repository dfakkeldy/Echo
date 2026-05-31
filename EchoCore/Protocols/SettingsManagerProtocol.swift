import Foundation

@MainActor protocol SettingsManagerProtocol: AnyObject {
    // MARK: - Appearance
    var isDarkMode: Bool { get set }
    var appFont: String { get set }
    var themeColor: String { get set }

    // MARK: - Smart Rewind
    var isRewindEnabled: Bool { get set }
    var rewindPauseSecondsThreshold: Int { get set }
    var rewindAmountAfterSeconds: Int { get set }
    var rewindPauseMinutesThreshold: Int { get set }
    var rewindAmountAfterMinutes: Int { get set }
    var rewindPauseHoursThreshold: Int { get set }
    var rewindAmountAfterHours: Int { get set }
    var rewindHoursToChapterStart: Bool { get set }

    // MARK: - Playback
    var playBookmarksInline: Bool { get set }

    // MARK: - Silence Detection
    var silenceDetectionLookbackSeconds: Double { get set }

    // MARK: - Watch
    var crownAction: String { get set }
    var crownVolumeSensitivity: Double { get set }
    var crownScrubSensitivity: Double { get set }
    var watchPage1: [WatchAction] { get set }
    var watchPage2: [WatchAction] { get set }
    var linearBarMode: String { get set }
    var linearBarHidden: Bool { get set }
    var circularRingMode: String { get set }
    var circularRingHidden: Bool { get set }
    var watchArtworkLayout: String { get set }
    var watchBackgroundStyle: String { get set }
    var isHapticFeedbackEnabled: Bool { get set }
    var watchQuickBookmarkTimeoutSeconds: Int { get set }

    // MARK: - Customizable Phone Controls & Presets
    var phonePage: [WatchAction] { get set }
    var seekBackwardDuration: Int { get set }
    var seekForwardDuration: Int { get set }
    var watchPresets: [WatchPreset] { get set }
    var phonePresets: [PhonePreset] { get set }

    static var systemFontName: String { get }
}
