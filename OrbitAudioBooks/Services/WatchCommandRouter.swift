import Foundation
import WatchConnectivity

@MainActor
protocol WatchCommandRoutingFacade: AnyObject {
    var currentPlaybackTime: TimeInterval { get }
    var durationSeconds: Double? { get }
    var speed: Float { get }
    var watchCommandOutputGain: Float { get }
    var watchThumbnailData: Data? { get }
    var crownScrubSensitivity: Double { get }
    var crownVolumeSensitivity: Double { get }

    func play()
    func pause()
    func togglePlayPause()
    func skipBackwardNavigation() -> Bool
    func skipForwardNavigation() -> Bool
    func skipBackward30() -> Bool
    func skipForward30() -> Bool
    func seek(toSeconds targetSeconds: Double)
    func seek(toFraction fraction: Double)
    func setSpeed(_ newSpeed: Float)
    func setWatchCommandOutputGain(_ gain: Float)
    func cycleLoopMode()
    func setSleepTimer(_ mode: SleepTimerMode)
    func cancelSleepTimer()
    func addBookmarkFromWatchCommand()
    func addWatchBookmark(from payload: [String: Any])
    func gradeFlashcard(cardID: String, grade: Int)
    func watchStateContext() -> [String: Any]
}

final class WatchCommandRouter {
    private weak var facade: WatchCommandRoutingFacade?

    init(facade: WatchCommandRoutingFacade) {
        self.facade = facade
    }

    func route(message: [String: Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let facade = self.facade else { return }

            var commandResult: String?
            if let command = message["command"] as? String {
                switch command {
                case "play":
                    facade.play()
                case "pause":
                    facade.pause()
                case "next":
                    if facade.skipForwardNavigation() { commandResult = "bookmarkJump" }
                case "previous":
                    if facade.skipBackwardNavigation() { commandResult = "bookmarkJump" }
                case "skipBackward":
                    if facade.skipBackward30() { commandResult = "bookmarkJump" }
                case "skipForward":
                    if facade.skipForward30() { commandResult = "bookmarkJump" }
                case "seek":
                    if let fraction = message["fraction"] as? Double {
                        facade.seek(toFraction: fraction)
                    }
                case "scrubDelta":
                    if let delta = message["delta"] as? Double {
                        let sensitivity = facade.crownScrubSensitivity
                        let multiplier = sensitivity > 0 ? sensitivity : SettingsManager.Defaults.crownScrubSensitivity
                        let duration = facade.durationSeconds ?? 0
                        let target = max(0, min(duration, facade.currentPlaybackTime + (delta * 30.0 * multiplier)))
                        facade.seek(toSeconds: target)
                    }
                case "volumeDelta":
                    if let delta = message["delta"] as? Double {
                        let sensitivity = facade.crownVolumeSensitivity
                        let multiplier = sensitivity > 0 ? sensitivity : SettingsManager.Defaults.crownVolumeSensitivity
                        let newGain = max(-40, min(9, facade.watchCommandOutputGain + Float(delta * 6 * multiplier)))
                        facade.setWatchCommandOutputGain(newGain)
                    }
                case "toggle":
                    facade.togglePlayPause()
                case "toggleLoopMode", "cycleLoopMode":
                    facade.cycleLoopMode()
                case "cycleSpeed":
                    if let newSpeed = message["playbackSpeed"] as? Double {
                        facade.setSpeed(Float(newSpeed))
                    } else {
                        let speeds: [Float] = [1.0, 1.25, 1.5, 2.0]
                        let idx = speeds.firstIndex(of: facade.speed) ?? -1
                        let next = speeds[(idx + 1) % speeds.count]
                        facade.setSpeed(next)
                    }
                case "setSleepTimer":
                    if let modeString = message["sleepTimerMode"] as? String {
                        switch modeString {
                        case "off":
                            facade.setSleepTimer(.off)
                        case "endOfChapter":
                            facade.setSleepTimer(.endOfChapter)
                        case "minutes":
                            let minutes = (message["sleepTimerMinutes"] as? Int) ?? 15
                            facade.setSleepTimer(.minutes(minutes))
                        default:
                            break
                        }
                    }
                case "cancelSleepTimer":
                    facade.cancelSleepTimer()
                case "addBookmark":
                    facade.addBookmarkFromWatchCommand()
                case "addWatchTextBookmark":
                    facade.addWatchBookmark(from: message)
                case "addWatchVoiceBookmark":
                    addWatchVoiceBookmark(from: message)
                case "gradeFlashcard":
                    if let cardID = message["cardID"] as? String,
                       let grade = message["grade"] as? Int {
                        facade.gradeFlashcard(cardID: cardID, grade: grade)
                    }
                case "requestState":
                    break
                default:
                    break
                }
            }

            var reply = facade.watchStateContext()
            if let thumbnailData = facade.watchThumbnailData {
                reply["thumbnailData"] = thumbnailData
            }
            if let commandResult {
                reply["commandResult"] = commandResult
            }
            replyHandler?(reply)
        }
    }

    func handleFile(_ file: WCSessionFile) {
        guard let command = file.metadata?["command"] as? String, command == "addWatchVoiceBookmark" else {
            return
        }

        let fileName = (file.metadata?["voiceMemoFileName"] as? String) ?? file.fileURL.lastPathComponent
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        let destinationURL = Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(safeFileName)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: destinationURL)
        } catch {
            print("Watch voice bookmark copy failed: \(error)")
            return
        }

        var metadata = file.metadata ?? [:]
        metadata["voiceMemoFileName"] = safeFileName

        DispatchQueue.main.async { [weak self] in
            self?.facade?.addWatchBookmark(from: metadata)
        }
    }

    private func addWatchVoiceBookmark(from payload: [String: Any]) {
        guard let voiceMemoData = payload["voiceMemoData"] as? Data else {
            return
        }

        let fileName = (payload["voiceMemoFileName"] as? String) ?? "watch-memo-\(UUID().uuidString).m4a"
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        let destinationURL = Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(safeFileName)
        var metadata = payload
        metadata["voiceMemoFileName"] = safeFileName
        metadata.removeValue(forKey: "voiceMemoData")

        let routingFacade = facade
        Task.detached(priority: .utility) {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try voiceMemoData.write(to: destinationURL, options: .atomic)
            } catch {
                print("Watch voice bookmark write failed: \(error)")
                return
            }

            await MainActor.run {
                routingFacade?.addWatchBookmark(from: metadata)
            }
        }
    }
}
