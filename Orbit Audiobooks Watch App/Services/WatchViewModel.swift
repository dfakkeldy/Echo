import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit
import os.log

/// Mutable playback state captured before an optimistic local update.
/// If the iPhone doesn't confirm within 3 seconds or reports an error,
/// the view model rolls back to this snapshot.
struct PlaybackSnapshot {
    var isPlaying: Bool
    var loopMode: String
    var currentSpeedIndex: Int
    var sleepTimerMode: String
    var sleepTimerMinutes: Int
    var sleepTimerRemainingSeconds: Int
}

@Observable @MainActor
class WatchViewModel: NSObject, WCSessionDelegate {
    /// Local cache of bookmarks created from the watch this session. Used to
    /// derive generic titles like `Bookmark #3` and to drive the local list
    /// view without waiting for a round-trip from the iPhone.
    var bookmarks: [WatchBookmark] = []
    private let logger = Logger(category: "WatchViewModel")
    var dueCards: [WatchFlashcard] = []

    var isPlaying: Bool = false
    var title: String = "No track selected"
    var thumbnailImage: UIImage? = nil
    var progressFraction: Double = 0.0
    var totalProgressFraction: Double = 0.0
    var totalBookDuration: Double = 0
    var chapterDuration: Double = 0
    
    @ObservationIgnored private var playbackTimer: Timer?
    @ObservationIgnored private var lastTimerTick: Date?
    /// When `true`, the linear progress bar should snap to the current value
    /// instead of animating. Driven by large state jumps (background wake-up).
    var progressAnimationSuppressed: Bool = true
    /// Same suppression for the circular ring, keyed off progressFraction jumps.
    var ringAnimationSuppressed: Bool = true
    var loopMode: String = "off"
    var bookmarkStorageKey: String? = nil
    var folderKey: String? = nil
    var trackId: String? = nil
    var currentTime: Double = 0
    var crownAction: String = AppGroupDefaults.shared.string(forKey: "crownAction") ?? "volume"

    // Sleep timer mirror state (driven by iPhone via WCSession context).
    /// "off" | "minutes" | "endOfChapter"
    var sleepTimerMode: String = "off"
    var sleepTimerMinutes: Int = 0
    var sleepTimerRemainingSeconds: Int = 0
    var isSleepTimerActive: Bool { sleepTimerMode != "off" }
    /// Computed property that always reads the latest value from App Group
    /// defaults, avoiding the stale-value problem of a closure-initialized stored
    /// property that is only read once at init.
    var watchQuickBookmarkTimeoutSeconds: Int {
        get {
            let raw = defaults.integer(forKey: "watchQuickBookmarkTimeoutSeconds")
            return raw > 0 ? raw : 5
        }
        set {
            defaults.set(newValue, forKey: "watchQuickBookmarkTimeoutSeconds")
        }
    }

    var seekBackwardDuration: Int = 30
    var seekForwardDuration: Int = 30

    var page1Slots: [WatchAction] = [.empty, .empty, .skipBackward, .playPause, .skipForward]
    var page2Slots: [WatchAction] = [.loopMode, .empty, .speed, .sleepTimer, .bookmark]
    var page3Slots: [WatchAction] = [.empty, .empty, .empty, .empty, .empty]
    var page4Slots: [WatchAction] = [.empty, .empty, .empty, .empty, .empty]
    var page5Slots: [WatchAction] = [.empty, .empty, .empty, .empty, .empty]

    // Progress indicator configuration (synced from iPhone)
    var linearBarMode: String = "total"
    var linearBarHidden: Bool = false
    var circularRingMode: String = "chapter"
    var circularRingHidden: Bool = false
    var watchArtworkLayout: String = "immersive"
    var watchBackgroundStyle: String = "artwork"

    /// Top words for the current chapter, received from the iPhone.
    var currentWordCloud: [WordFrequency] = []

    let availableSpeeds: [Double] = [1.0, 1.25, 1.5, 2.0, 3.0]
    var currentSpeedIndex: Int = 0
    var playbackSpeed: Double { availableSpeeds[currentSpeedIndex] }

    @ObservationIgnored private let defaults = AppGroupDefaults.shared

    /// Debounce widget timeline reloads to at most once per 30 seconds,
    /// instead of firing on every `applyState` call (which can happen
    /// multiple times per second during playback sync).
    @ObservationIgnored private var lastWidgetReload: Date = .distantPast

    /// Plays a haptic only when the user has haptic feedback enabled in settings.
    /// Centralises the gate so individual call sites don't repeat the check.
    private func playHaptic(_ type: WKHapticType) {
        guard defaults.bool(forKey: "isHapticFeedbackEnabled") else { return }
        WKInterfaceDevice.current().play(type)
    }

    // MARK: Optimistic update rollback

    @ObservationIgnored private var pendingSnapshot: PlaybackSnapshot?
    @ObservationIgnored private var rollbackTimer: Timer?

    func prepareOptimisticUpdate() {
        rollbackTimer?.invalidate()
        pendingSnapshot = PlaybackSnapshot(
            isPlaying: isPlaying,
            loopMode: loopMode,
            currentSpeedIndex: currentSpeedIndex,
            sleepTimerMode: sleepTimerMode,
            sleepTimerMinutes: sleepTimerMinutes,
            sleepTimerRemainingSeconds: sleepTimerRemainingSeconds
        )
    }

    private func rollback() {
        guard let snapshot = pendingSnapshot else { return }
        isPlaying = snapshot.isPlaying
        loopMode = snapshot.loopMode
        currentSpeedIndex = snapshot.currentSpeedIndex
        sleepTimerMode = snapshot.sleepTimerMode
        sleepTimerMinutes = snapshot.sleepTimerMinutes
        sleepTimerRemainingSeconds = snapshot.sleepTimerRemainingSeconds
        pendingSnapshot = nil
        rollbackTimer?.invalidate()
        rollbackTimer = nil
    }

    private func clearPendingRollback() {
        pendingSnapshot = nil
        rollbackTimer?.invalidate()
        rollbackTimer = nil
    }

    private func scheduleRollback() {
        rollbackTimer?.invalidate()
        rollbackTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.rollback()
                self?.requestCurrentState()
            }
        }
    }

    private func updatePlaybackTimer() {
        if isPlaying {
            if playbackTimer == nil {
                lastTimerTick = Date()
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.tickPlayback()
                }
            }
        } else {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }
    }
    
    private func tickPlayback() {
        guard let lastTick = lastTimerTick else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTimerTick = now
        
        let delta = elapsed * playbackSpeed
        currentTime += delta
        
        if totalBookDuration > 0 {
            let frac = min(1.0, max(0.0, currentTime / totalBookDuration))
            self.totalProgressFraction = frac
        }
        
        if chapterDuration > 0 {
            let newFrac = min(1.0, max(0.0, progressFraction + (delta / chapterDuration)))
            self.progressFraction = newFrac
        } else if totalBookDuration > 0 {
            self.progressFraction = self.totalProgressFraction
        }
    }

    override init() {
        super.init()
        AppGroupDefaults.migrateStandardDefaultsIfNeeded()
        loadPersistedState()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    private func loadPersistedState() {
        isPlaying = defaults.bool(forKey: "isPlaying")
        title = defaults.string(forKey: "title") ?? "No track selected"
        progressFraction = defaults.double(forKey: "progressFraction")
        totalBookDuration = defaults.double(forKey: "totalBookDuration")
        loopMode = defaults.string(forKey: "loopMode") ?? "off"
        currentTime = defaults.double(forKey: "currentTime")
        chapterDuration = defaults.double(forKey: "chapterDuration")
        if let storedSpeed = defaults.object(forKey: "playbackSpeed") as? Double,
           let idx = availableSpeeds.firstIndex(where: { abs($0 - storedSpeed) < 0.001 }) {
            currentSpeedIndex = idx
        }
        bookmarkStorageKey = defaults.string(forKey: "bookmarkStorageKey")
        folderKey = defaults.string(forKey: "folderKey")
        trackId = defaults.string(forKey: "trackId")
        crownAction = defaults.string(forKey: "crownAction") ?? "volume"
        seekBackwardDuration = defaults.integer(forKey: "seekBackwardDuration")
        if seekBackwardDuration == 0 { seekBackwardDuration = 30 }
        seekForwardDuration = defaults.integer(forKey: "seekForwardDuration")
        if seekForwardDuration == 0 { seekForwardDuration = 30 }

        if let thumbnailData = defaults.data(forKey: "thumbnailData"),
           let image = UIImage(data: thumbnailData) {
            thumbnailImage = image
        }

        if let data = defaults.data(forKey: "watchPage1"),
           let decoded = try? JSONDecoder().decode([WatchAction].self, from: data) {
            page1Slots = padded(decoded)
        } else if let raw = defaults.string(forKey: "watchPage1") {
            // Migration from old comma-separated format
            page1Slots = padded(parseSlots(raw))
        }
        if let data = defaults.data(forKey: "watchPage2"),
           let decoded = try? JSONDecoder().decode([WatchAction].self, from: data) {
            page2Slots = padded(decoded)
        } else if let raw = defaults.string(forKey: "watchPage2") {
            // Migration from old comma-separated format
            page2Slots = padded(parseSlots(raw))
        }
        if let data = defaults.data(forKey: "watchPage3"),
           let decoded = try? JSONDecoder().decode([WatchAction].self, from: data) {
            page3Slots = padded(decoded)
        }
        if let data = defaults.data(forKey: "watchPage4"),
           let decoded = try? JSONDecoder().decode([WatchAction].self, from: data) {
            page4Slots = padded(decoded)
        }
        if let data = defaults.data(forKey: "watchPage5"),
           let decoded = try? JSONDecoder().decode([WatchAction].self, from: data) {
            page5Slots = padded(decoded)
        }

        linearBarMode = defaults.string(forKey: "linearBarMode") ?? "total"
        linearBarHidden = defaults.bool(forKey: "linearBarHidden")
        circularRingMode = defaults.string(forKey: "circularRingMode") ?? "chapter"
        circularRingHidden = defaults.bool(forKey: "circularRingHidden")
        watchArtworkLayout = defaults.string(forKey: "watchArtworkLayout") ?? "immersive"
        watchBackgroundStyle = defaults.string(forKey: "watchBackgroundStyle") ?? "artwork"
    }

    private func parseSlots(_ raw: String) -> [WatchAction] {
        raw.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
    }

    private func padded(_ slots: [WatchAction]) -> [WatchAction] {
        var out = Array(slots.prefix(5))
        while out.count < 5 { out.append(.empty) }
        return out
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else {
            if let error {
                logger.error("WatchConnectivity activation failed: \(error)")
            }
            return
        }
        requestCurrentState()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        requestCurrentState()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        guard session.activationState == .activated else { return }
        applyState(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard session.activationState == .activated else { return }
        applyState(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        guard session.activationState == .activated else {
            replyHandler([:])
            return
        }
        applyState(message)
        replyHandler(["handled": true])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        guard session.activationState == .activated else { return }
        applyState(userInfo)
    }

    private func applyState(_ state: [String: Any]) {
        guard !state.isEmpty else { return }
        Task { @MainActor in
            let previousTrackId = self.trackId

            if let crownAction = state["crownAction"] as? String {
                self.crownAction = crownAction
                self.defaults.set(crownAction, forKey: "crownAction")
            }
            if let isHapticEnabled = state["isHapticFeedbackEnabled"] as? Bool {
                self.defaults.set(isHapticEnabled, forKey: "isHapticFeedbackEnabled")
            }
            if let timeoutSeconds = state["watchQuickBookmarkTimeoutSeconds"] as? Int {
                self.watchQuickBookmarkTimeoutSeconds = max(1, timeoutSeconds)
            }
            if let seekBackwardDuration = state["seekBackwardDuration"] as? Int {
                self.seekBackwardDuration = seekBackwardDuration
                self.defaults.set(seekBackwardDuration, forKey: "seekBackwardDuration")
            }
            if let seekForwardDuration = state["seekForwardDuration"] as? Int {
                self.seekForwardDuration = seekForwardDuration
                self.defaults.set(seekForwardDuration, forKey: "seekForwardDuration")
            }
            if let isPlaying = state["isPlaying"] as? Bool {
                self.isPlaying = isPlaying
                self.defaults.set(isPlaying, forKey: "isPlaying")
            }
            if let title = state["title"] as? String {
                self.title = title
                self.defaults.set(title, forKey: "title")
            }
            if let progressFraction = state["progressFraction"] as? Double {
                let delta = abs(progressFraction - self.progressFraction)
                if delta > 0.02 {
                    self.ringAnimationSuppressed = true
                }
                self.progressFraction = progressFraction
                self.defaults.set(progressFraction, forKey: "progressFraction")
                if delta > 0.02 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.5))
                        self?.ringAnimationSuppressed = false
                    }
                }
            } else {
                self.ringAnimationSuppressed = false
            }
            if let totalProgressFraction = state["totalProgressFraction"] as? Double {
                let delta = abs(totalProgressFraction - self.totalProgressFraction)
                // Large jumps (>2%) indicate a background wake-up sync —
                // suppress animation so the bar snaps instead of playing
                // catch-up through every intermediate value.
                if delta > 0.02 {
                    self.progressAnimationSuppressed = true
                }
                self.totalProgressFraction = totalProgressFraction
                self.defaults.set(totalProgressFraction, forKey: "totalProgressFraction")
                if delta > 0.02 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.5))
                        self?.progressAnimationSuppressed = false
                    }
                }
            } else {
                self.progressAnimationSuppressed = false
            }
            if let totalBookDuration = state["totalBookDuration"] as? Double {
                self.totalBookDuration = totalBookDuration
                self.defaults.set(totalBookDuration, forKey: "totalBookDuration")
            }
            if let chapterDuration = state["chapterDuration"] as? Double {
                self.chapterDuration = chapterDuration
                self.defaults.set(chapterDuration, forKey: "chapterDuration")
            }
            if let currentTime = state["currentTime"] as? Double {
                self.currentTime = currentTime
                self.defaults.set(currentTime, forKey: "currentTime")
            }
            if let bookmarkStorageKey = state["bookmarkStorageKey"] as? String {
                self.bookmarkStorageKey = bookmarkStorageKey
                self.defaults.set(bookmarkStorageKey, forKey: "bookmarkStorageKey")
            }
            if let folderKey = state["folderKey"] as? String {
                self.folderKey = folderKey
                self.defaults.set(folderKey, forKey: "folderKey")
            }
            if let trackId = state["trackId"] as? String {
                self.trackId = trackId
                self.defaults.set(trackId, forKey: "trackId")
            }
            if let loopMode = state["loopMode"] as? String {
                self.loopMode = loopMode
                self.defaults.set(loopMode, forKey: "loopMode")
            }
            if let stm = state["sleepTimerMode"] as? String {
                self.sleepTimerMode = stm
            }
            if let mins = state["sleepTimerMinutes"] as? Int {
                self.sleepTimerMinutes = mins
            }
            if let rem = state["sleepTimerRemainingSeconds"] as? Int {
                self.sleepTimerRemainingSeconds = rem
            }
            if let playbackSpeed = state["playbackSpeed"] as? Double,
               let idx = self.availableSpeeds.firstIndex(where: { abs($0 - playbackSpeed) < 0.001 }) {
                self.currentSpeedIndex = idx
                self.defaults.set(playbackSpeed, forKey: "playbackSpeed")
            }
            if let watchPage1Data = state["watchPage1"] as? Data,
               let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage1Data) {
                self.page1Slots = self.padded(decoded)
                self.defaults.set(watchPage1Data, forKey: "watchPage1")
            }
            if let watchPage2Data = state["watchPage2"] as? Data,
               let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage2Data) {
                self.page2Slots = self.padded(decoded)
                self.defaults.set(watchPage2Data, forKey: "watchPage2")
            }
            if let watchPage3Data = state["watchPage3"] as? Data,
               let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage3Data) {
                self.page3Slots = self.padded(decoded)
                self.defaults.set(watchPage3Data, forKey: "watchPage3")
            }
            if let watchPage4Data = state["watchPage4"] as? Data,
               let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage4Data) {
                self.page4Slots = self.padded(decoded)
                self.defaults.set(watchPage4Data, forKey: "watchPage4")
            }
            if let watchPage5Data = state["watchPage5"] as? Data,
               let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage5Data) {
                self.page5Slots = self.padded(decoded)
                self.defaults.set(watchPage5Data, forKey: "watchPage5")
            }
            if let linearBarMode = state["linearBarMode"] as? String {
                self.linearBarMode = linearBarMode
                self.defaults.set(linearBarMode, forKey: "linearBarMode")
            }
            if let linearBarHidden = state["linearBarHidden"] as? Bool {
                self.linearBarHidden = linearBarHidden
                self.defaults.set(linearBarHidden, forKey: "linearBarHidden")
            }
            if let circularRingMode = state["circularRingMode"] as? String {
                self.circularRingMode = circularRingMode
                self.defaults.set(circularRingMode, forKey: "circularRingMode")
            }
            if let circularRingHidden = state["circularRingHidden"] as? Bool {
                self.circularRingHidden = circularRingHidden
                self.defaults.set(circularRingHidden, forKey: "circularRingHidden")
            }
            if let watchArtworkLayout = state["watchArtworkLayout"] as? String {
                self.watchArtworkLayout = watchArtworkLayout
                self.defaults.set(watchArtworkLayout, forKey: "watchArtworkLayout")
            }
            if let watchBackgroundStyle = state["watchBackgroundStyle"] as? String {
                self.watchBackgroundStyle = watchBackgroundStyle
                self.defaults.set(watchBackgroundStyle, forKey: "watchBackgroundStyle")
            }
            if let thumbnailData = state["thumbnailData"] as? Data {
                self.defaults.set(thumbnailData, forKey: "thumbnailData")
                if let image = UIImage(data: thumbnailData) {
                    self.thumbnailImage = image
                }
            } else if state["trackId"] != nil, self.trackId != previousTrackId {
                // Track changed — the old thumbnail is stale. Clear it so the
                // placeholder shows until the iPhone sends a fresh thumbnail
                // payload for the new track.
                self.defaults.removeObject(forKey: "thumbnailData")
                self.thumbnailImage = nil
            }
            if let wordCloudJSON = state["wordCloudJSON"] as? String,
               let jsonData = wordCloudJSON.data(using: .utf8),
               let words = try? JSONDecoder().decode([WordFrequency].self, from: jsonData) {
                self.currentWordCloud = words
            }

            if let dueCardsJSON = state["dueCardsJSON"] as? String,
               let jsonData = dueCardsJSON.data(using: .utf8),
               let cards = try? JSONDecoder().decode([WatchFlashcard].self, from: jsonData) {
                self.dueCards = cards
            }

            if state["commandResult"] as? String == "bookmarkJump" {
                self.playHaptic(.success)
            }
            let now = Date()
            if now.timeIntervalSince(self.lastWidgetReload) >= 30 {
                self.lastWidgetReload = now
                WidgetCenter.shared.reloadTimelines(ofKind: "Orbit_Audiobooks_Widget")
            }
            self.updatePlaybackTimer()
        }
    }

    /// Sends a flashcard grade back to iPhone for SM-2 processing and persistence.
    func gradeFlashcard(cardID: String, grade: Int) {
        dueCards.removeAll { $0.id == cardID }
        _ = sendCommand("gradeFlashcard", params: ["cardID": cardID, "grade": grade])
    }

    func requestCurrentState() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["command": "requestState"], replyHandler: { [weak self] reply in
            self?.applyState(reply)
        }, errorHandler: { error in
            logger.error("Error requesting state: \(error)")
        })
    }

    private static func isDirectionalCommand(_ command: String) -> Bool {
        command == "next" || command == "previous" || command == "skipForward" || command == "skipBackward"
    }

    private static func isForwardCommand(_ command: String) -> Bool {
        command == "next" || command == "skipForward"
    }

    @discardableResult
    func sendCommand(_ command: String, params: [String: Any]? = nil) -> Bool {
        guard !command.isEmpty else { return false }
        let session = WCSession.default

        guard session.activationState == .activated else {
            rollback()
            requestCurrentState()
            return false
        }

        var message: [String: Any] = ["command": command]
        if let params = params {
            for (key, value) in params {
                message[key] = value
            }
        }

        if session.isReachable {
            session.sendMessage(message, replyHandler: { [weak self] reply in
                self?.clearPendingRollback()
                self?.applyState(reply)
                if Self.isDirectionalCommand(command),
                   self?.loopMode == "bookmark",
                   reply["commandResult"] as? String != "bookmarkJump" {
                    self?.playHaptic(Self.isForwardCommand(command) ? .directionUp : .directionDown)
                }
            }, errorHandler: { [weak self] error in
                logger.error("Error sending command: \(error)")
                self?.rollback()
                self?.requestCurrentState()
            })
            if pendingSnapshot != nil {
                scheduleRollback()
            }
        } else {
            // Fallback for background communication when iPhone is locked/backgrounded.
            // transferUserInfo queues the payload to be delivered even if the counterpart is suspended.
            session.transferUserInfo(message)
            // Since we won't get a reply handler callback, clear the rollback timer so the UI
            // doesn't revert prematurely before the iPhone wakes up and syncs the new state.
            clearPendingRollback()
        }

        if loopMode == "bookmark" && Self.isDirectionalCommand(command) {
            return true
        }

        let hapticType: WKHapticType = {
            switch command {
            case "skipBackward", "previous":
                return .directionDown
            default:
                return .directionUp
            }
        }()
        self.playHaptic(hapticType)

        return true
    }

    /// Trigger the action for a tapped slot, with optimistic local state
    /// updates so the UI feels instant. A snapshot is captured before each
    /// mutation; if the iPhone doesn't confirm within 3 seconds or reports
    /// an error, the view model rolls back to the snapshot.
    func handle(_ action: WatchAction) {
        switch action {
        case .empty:
            return
        case .playPause:
            prepareOptimisticUpdate()
            isPlaying.toggle()
            updatePlaybackTimer()
            sendCommand(isPlaying ? "play" : "pause")
        case .loopMode:
            prepareOptimisticUpdate()
            let modes = ["off", "chapter", "bookmark"]
            let currentIndex = modes.firstIndex(of: loopMode) ?? 0
            let next = modes[(currentIndex + 1) % modes.count]
            loopMode = next
            defaults.set(next, forKey: "loopMode")
            sendCommand("cycleLoopMode")
        case .speed:
            prepareOptimisticUpdate()
            cycleSpeed()
        default:
            sendCommand(action.command)
        }
    }

    // MARK: Sleep Timer (watch -> iPhone)

    func setSleepTimerMinutes(_ minutes: Int) {
        prepareOptimisticUpdate()
        // Optimistic local state update for immediate UI feedback.
        sleepTimerMode = "minutes"
        sleepTimerMinutes = minutes
        sleepTimerRemainingSeconds = minutes * 60
        sendCommand("setSleepTimer", params: [
            "sleepTimerMode": "minutes",
            "sleepTimerMinutes": minutes
        ])
    }

    func setSleepTimerEndOfChapter() {
        prepareOptimisticUpdate()
        sleepTimerMode = "endOfChapter"
        sleepTimerMinutes = 0
        sleepTimerRemainingSeconds = 0
        sendCommand("setSleepTimer", params: [
            "sleepTimerMode": "endOfChapter"
        ])
    }

    func cancelSleepTimer() {
        prepareOptimisticUpdate()
        sleepTimerMode = "off"
        sleepTimerMinutes = 0
        sleepTimerRemainingSeconds = 0
        sendCommand("cancelSleepTimer")
    }

    func cycleSpeed() {
        currentSpeedIndex = (currentSpeedIndex + 1) % availableSpeeds.count
        let newSpeed = availableSpeeds[currentSpeedIndex]
        defaults.set(newSpeed, forKey: "playbackSpeed")
        sendCommand("cycleSpeed", params: ["playbackSpeed": newSpeed])
    }

    func queueTextBookmark(note: String) throws {
        var payload = try bookmarkPayload(command: "addWatchTextBookmark")
        payload["note"] = note
        WCSession.default.transferUserInfo(payload)
        playHaptic(.success)
    }

    func queueVoiceBookmark(fileURL: URL) async throws {
        // Use transferFile instead of inline Data to avoid the ~65KB payload
        // limit of sendMessage / transferUserInfo. The phone-side
        // WatchCommandRouter.handleFile(_:) already handles this path.
        var metadata = try bookmarkPayload(command: "addWatchVoiceBookmark")
        metadata["voiceMemoFileName"] = fileURL.lastPathComponent

        let session = WCSession.default
        guard session.activationState == .activated else {
            throw WatchBookmarkError.watchConnectivityInactive
        }

        // Copy to a temp location so transferFile can take ownership.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch_voice_memo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: tempURL)

        session.transferFile(tempURL, metadata: metadata)
        playHaptic(.success)
        addBookmark(audioURL: fileURL)
    }

    // MARK: Bookmark Creation

    /// Append a new bookmark to the local in-memory store. When `audioURL`
    /// is `nil`, generates a generic title using the existing array count
    /// (e.g. `"Bookmark #3"`).
    @discardableResult
    func addBookmark(audioURL: URL? = nil, title: String? = nil) -> WatchBookmark {
        let resolvedTitle = title ?? "Bookmark #\(bookmarks.count + 1)"
        let bookmark = WatchBookmark(
            title: resolvedTitle,
            timestamp: max(0, currentTime),
            audioURL: audioURL
        )
        bookmarks.append(bookmark)
        return bookmark
    }

    /// One-tap "Quick Bookmark" creation. Bypasses the recorder entirely and
    /// dispatches a text-style bookmark with a generic title to the iPhone.
    func addQuickBookmark() {
        let bookmark = addBookmark()
        do {
            try queueTextBookmark(note: bookmark.title)
        } catch {
            // Roll back the local bookmark if the iPhone could not be reached;
            // surface only via haptic since the watch UI is intentionally tiny.
            bookmarks.removeAll { $0.id == bookmark.id }
            logger.error("Quick bookmark failed: \(error.localizedDescription)")
            playHaptic(.failure)
        }
    }


    private func bookmarkPayload(command: String) throws -> [String: Any] {
        guard WCSession.isSupported() else {
            throw WatchBookmarkError.watchConnectivityUnavailable
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            throw WatchBookmarkError.watchConnectivityInactive
        }

        guard let bookmarkStorageKey else {
            throw WatchBookmarkError.noActiveBook
        }

        var payload: [String: Any] = [
            "command": command,
            "bookmarkID": UUID().uuidString,
            "bookmarkStorageKey": bookmarkStorageKey,
            "timestamp": max(0, currentTime),
            "createdAt": Date().timeIntervalSince1970
        ]

        if let folderKey {
            payload["folderKey"] = folderKey
        }
        if let trackId {
            payload["trackId"] = trackId
        }

        return payload
    }
}

enum WatchBookmarkError: LocalizedError {
    case watchConnectivityUnavailable
    case watchConnectivityInactive
    case noActiveBook

    var errorDescription: String? {
        switch self {
        case .watchConnectivityUnavailable:
            return "Watch sync is not available on this device."
        case .watchConnectivityInactive:
            return "Watch sync is still starting. Try again in a moment."
        case .noActiveBook:
            return "Start playback on iPhone before creating a bookmark."
        }
    }
}
