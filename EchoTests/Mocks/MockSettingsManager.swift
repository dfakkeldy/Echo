import Foundation
@testable import Echo

/// In-memory SettingsManager for unit testing.
final class MockSettingsManager: SettingsManagerProtocol {
    var isDarkMode: Bool = true
    var appFont: String = "Lexend"
    var themeColor: String = "System"

    var isRewindEnabled: Bool = false
    var rewindPauseSecondsThreshold: Int = 30
    var rewindAmountAfterSeconds: Int = 10
    var rewindPauseMinutesThreshold: Int = 5
    var rewindAmountAfterMinutes: Int = 30
    var rewindPauseHoursThreshold: Int = 1
    var rewindAmountAfterHours: Int = 90
    var rewindHoursToChapterStart: Bool = false

    var playBookmarksInline: Bool = true

    var silenceDetectionLookbackSeconds: Double = 10.0

    var crownAction: String = "volume"
    var crownVolumeSensitivity: Double = 0.05
    var crownScrubSensitivity: Double = 0.5
    var watchPage1: [WatchAction] = [.empty, .empty, .skipBackward, .playPause, .skipForward]
    var watchPage2: [WatchAction] = [.loopMode, .empty, .speed, .sleepTimer, .bookmark]
    var linearBarMode: String = "total"
    var linearBarHidden: Bool = false
    var circularRingMode: String = "chapter"
    var circularRingHidden: Bool = false
    var watchArtworkLayout: String = "immersive"
    var watchBackgroundStyle: String = "artwork"
    var isHapticFeedbackEnabled: Bool = true
    var watchQuickBookmarkTimeoutSeconds: Int = 5

    var phonePage: [WatchAction] = [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]
    var seekBackwardDuration: Int = 30
    var seekForwardDuration: Int = 30
    var watchPresets: [WatchPreset] = []
    var phonePresets: [PhonePreset] = []

    var autoAlignmentEnabled: Bool = true
    var autoAlignmentModelSize: String = "base.en"
    var autoAlignmentChapterSnapEnabled: Bool = true
    var autoAlignmentDriftDetectionEnabled: Bool = true
    var autoAlignmentDriftRepairEnabled: Bool = true
    var continuousAutoAlignmentEnabled: Bool = false

    static var systemFontName: String { "System" }
}
