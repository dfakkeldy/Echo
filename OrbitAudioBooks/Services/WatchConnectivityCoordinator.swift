import Foundation
import WatchConnectivity

/// Coordinates watch command routing by adapting PlayerModel to the
/// WatchCommandRoutingFacade protocol, decoupling the router from the model.
@MainActor
final class WatchConnectivityCoordinator: WatchCommandRoutingFacade {
    private weak var playerModel: PlayerModel?

    init(playerModel: PlayerModel) {
        self.playerModel = playerModel
    }

    // MARK: - WatchCommandRoutingFacade

    var currentPlaybackTime: TimeInterval { playerModel?.currentPlaybackTime ?? 0 }
    var durationSeconds: Double? { playerModel?.durationSeconds }
    var speed: Float { playerModel?.speed ?? 1.0 }
    var watchCommandOutputGain: Float { playerModel?.watchCommandOutputGain ?? 0 }
    var watchThumbnailData: Data? { playerModel?.watchThumbnailData }
    var crownScrubSensitivity: Double { playerModel?.crownScrubSensitivity ?? SettingsManager.Defaults.crownScrubSensitivity }
    var crownVolumeSensitivity: Double { playerModel?.crownVolumeSensitivity ?? SettingsManager.Defaults.crownVolumeSensitivity }

    func play() { playerModel?.play() }
    func pause() { playerModel?.pause() }
    func togglePlayPause() { playerModel?.togglePlayPause() }
    func skipBackwardNavigation() -> Bool { playerModel?.skipBackwardNavigation() ?? false }
    func skipForwardNavigation() -> Bool { playerModel?.skipForwardNavigation() ?? false }
    func skipBackward30() -> Bool { playerModel?.skipBackward30() ?? false }
    func skipForward30() -> Bool { playerModel?.skipForward30() ?? false }
    func seek(toSeconds targetSeconds: Double) { playerModel?.seek(toSeconds: targetSeconds) }
    func seek(toFraction fraction: Double) { playerModel?.seek(toFraction: fraction) }
    func setSpeed(_ newSpeed: Float) { playerModel?.setSpeed(newSpeed) }
    func setWatchCommandOutputGain(_ gain: Float) { playerModel?.setWatchCommandOutputGain(gain) }
    func cycleLoopMode() { playerModel?.cycleLoopMode() }
    func setSleepTimer(_ mode: SleepTimerMode) { playerModel?.setSleepTimer(mode) }
    func cancelSleepTimer() { playerModel?.cancelSleepTimer() }
    func addBookmarkFromWatchCommand() { playerModel?.addBookmarkFromWatchCommand() }
    func addWatchBookmark(from payload: [String: Any]) { playerModel?.addWatchBookmark(from: payload) }
    func gradeFlashcard(cardID: String, grade: Int) { playerModel?.gradeFlashcard(cardID: cardID, grade: grade) }
    func watchStateContext() -> [String: Any] { playerModel?.watchStateContext() ?? [:] }
}
