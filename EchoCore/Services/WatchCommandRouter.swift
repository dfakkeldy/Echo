// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WatchConnectivity
import os.log

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
    func nextSection()
    func previousSectionOrRestart()
    func skipBackward30() -> Bool
    func skipForward30() -> Bool
    func seek(toSeconds targetSeconds: Double)
    func seek(toFraction fraction: Double)
    func setSpeed(_ newSpeed: Float)
    func setWatchCommandOutputGain(_ gain: Float)
    func cycleLoopMode()
    func setSleepTimer(_ mode: SleepTimerMode)
    func cancelSleepTimer()
    func toggleSleepTimer()
    func addBookmarkFromWatchCommand()
    func addWatchBookmark(from payload: [String: Any])
    func markPassageFromWatchCommand()
    func gradeFlashcard(cardID: String, grade: Int)
    func watchStateContext() -> [String: Any]
}

@MainActor
final class WatchCommandRouter {
    private let facade: WatchCommandRoutingFacade

    init(facade: WatchCommandRoutingFacade) {
        self.facade = facade
    }

    func route(message: [String: Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        let facade = self.facade

        var commandResult: String?
        if let command = message[WatchMessageKey.command] as? String {
            switch command {
            case "play":
                facade.play()
            case "pause":
                facade.pause()
            case "next":
                if facade.skipForwardNavigation() { commandResult = "bookmarkJump" }
            case "previous":
                if facade.skipBackwardNavigation() { commandResult = "bookmarkJump" }
            case "nextSection":
                facade.nextSection()
            case "previousSection":
                facade.previousSectionOrRestart()
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
                    let speeds = SettingsManager.Defaults.speedPresets
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
            case "toggleSleepTimer":
                facade.toggleSleepTimer()
            case "addBookmark":
                facade.addBookmarkFromWatchCommand()
            case "markPassage":
                facade.markPassageFromWatchCommand()
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

    /// Commands that stay meaningful even when delivered late. These carry their
    /// own context (a bookmark's timestamp, a flashcard's grade) so replaying them
    /// after a delay still does the right thing. Everything else is transport,
    /// navigation, seek, speed or sleep-timer state that is only valid "right now".
    private static let deferredSafeCommands: Set<String> = [
        "addBookmark", "addWatchTextBookmark", "addWatchVoiceBookmark", "gradeFlashcard"
    ]

    /// Routes a payload that arrived via the persistent background queue
    /// (`WCSession.transferUserInfo` → `didReceiveUserInfo`). That queue drains
    /// FIFO whenever the phone next becomes reachable — possibly minutes later or
    /// on a subsequent launch — so any time-sensitive command in it is stale and
    /// would fight the user (phantom play/pause, surprise seeks). Only deferred-safe
    /// commands are honored here; the rest are dropped. Live commands continue to
    /// flow through `route(message:replyHandler:)`.
    func route(queuedMessage message: [String: Any]) {
        guard let command = message[WatchMessageKey.command] as? String,
              Self.deferredSafeCommands.contains(command) else {
            return
        }
        route(message: message)
    }

    func handleFile(_ file: WCSessionFile) {
        guard let command = file.metadata?[WatchMessageKey.command] as? String, command == "addWatchVoiceBookmark" else {
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
            os_log(.error, "Watch voice bookmark copy failed: %{private}@", error.localizedDescription)
            return
        }

        var metadata = file.metadata ?? [:]
        metadata["voiceMemoFileName"] = safeFileName

        self.facade.addWatchBookmark(from: metadata)
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
                os_log(.error, "Watch voice bookmark write failed: %{private}@", error.localizedDescription)
                return
            }

            await MainActor.run {
                routingFacade.addWatchBookmark(from: metadata)
            }
        }
    }
}
