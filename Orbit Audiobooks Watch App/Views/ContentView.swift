import SwiftUI
import AVFoundation
import WatchConnectivity
import WatchKit
import Observation
import WidgetKit

enum AppGroupDefaults {
    static let suiteName = "group.com.orbitaudiobooks"
    private static let migrationKey = "didMigrateWidgetDefaultsToAppGroup"

    static var shared: UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            #if DEBUG
            assertionFailure("Unable to open app-group UserDefaults suite: \(suiteName)")
            #endif
            return .standard
        }
        return defaults
    }

    static var isHapticFeedbackEnabled: Bool {
        get { shared.object(forKey: "isHapticFeedbackEnabled") as? Bool ?? true }
        set { shared.set(newValue, forKey: "isHapticFeedbackEnabled") }
    }

    static var watchQuickBookmarkTimeoutSeconds: Int {
        get { shared.object(forKey: "watchQuickBookmarkTimeoutSeconds") as? Int ?? 5 }
        set { shared.set(max(1, newValue), forKey: "watchQuickBookmarkTimeoutSeconds") }
    }

    static var linearBarMode: String {
        get { shared.string(forKey: "linearBarMode") ?? "total" }
        set { shared.set(newValue, forKey: "linearBarMode") }
    }

    static var linearBarHidden: Bool {
        get { shared.bool(forKey: "linearBarHidden") }
        set { shared.set(newValue, forKey: "linearBarHidden") }
    }

    static var circularRingMode: String {
        get { shared.string(forKey: "circularRingMode") ?? "chapter" }
        set { shared.set(newValue, forKey: "circularRingMode") }
    }

    static var circularRingHidden: Bool {
        get { shared.bool(forKey: "circularRingHidden") }
        set { shared.set(newValue, forKey: "circularRingHidden") }
    }

    static func migrateStandardDefaultsIfNeeded() {
        guard let groupedDefaults = UserDefaults(suiteName: suiteName),
              !groupedDefaults.bool(forKey: migrationKey) else {
            return
        }

        let keys = [
            "isPlaying",
            "title",
            "progressFraction",
            "loopMode",
            "currentTime",
            "playbackSpeed",
            "bookmarkStorageKey",
            "folderKey",
            "trackId",
            "totalBookDuration",
            "thumbnailData",
            "watchPage1",
            "watchPage2",
            "crownAction",
            "isHapticFeedbackEnabled",
            "watchQuickBookmarkTimeoutSeconds",
            "linearBarMode",
            "linearBarHidden",
            "circularRingMode",
            "circularRingHidden"
        ]

        for key in keys {
            guard groupedDefaults.object(forKey: key) == nil,
                  let value = UserDefaults.standard.object(forKey: key) else {
                continue
            }
            groupedDefaults.set(value, forKey: key)
        }

        groupedDefaults.set(true, forKey: migrationKey)
    }
}

// MARK: - WatchAction

enum WatchAction: String, Codable, CaseIterable, Identifiable {
    case playPause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    case loopMode
    case speed
    case sleepTimer
    case bookmark
    case empty

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .playPause:     return "playpause.fill"
        case .skipForward:   return "goforward.30"
        case .skipBackward:  return "gobackward.30"
        case .nextTrack:     return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        case .loopMode:      return "infinity"
        case .speed:         return "gauge.medium"
        case .sleepTimer:    return "moon.zzz.fill"
        case .bookmark:      return "bookmark.fill"
        case .empty:         return "plus"
        }
    }

    var command: String {
        switch self {
        case .playPause:     return "toggle"
        case .skipForward:   return "skipForward"
        case .skipBackward:  return "skipBackward"
        case .nextTrack:     return "next"
        case .previousTrack: return "previous"
        case .loopMode:      return "cycleLoopMode"
        case .speed:         return "cycleSpeed"
        case .sleepTimer:    return "toggleSleepTimer"
        case .bookmark:      return "addBookmark"
        case .empty:         return ""
        }
    }
}

enum WatchSlotConfiguration {
    static func actions(from raw: String) -> [WatchAction] {
        padded(raw.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) })
    }

    static func padded(_ slots: [WatchAction]) -> [WatchAction] {
        var actions = Array(slots.prefix(5))
        while actions.count < 5 {
            actions.append(.empty)
        }
        return actions
    }
}

// MARK: - Watch Bookmark Model
//
// A lightweight bookmark representation used by the watch app to track
// bookmarks the user has queued during the current session. The audio
// file reference is intentionally `Optional` so that quick, generic
// bookmarks can be created without invoking the microphone.
struct WatchBookmark: Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var timestamp: TimeInterval
    var createdAt: Date
    /// Optional local audio file URL. When `nil`, this is a "quick" bookmark
    /// created without a voice memo and the playback controls should not be
    /// rendered for its row.
    var audioURL: URL?

    var hasAudio: Bool { audioURL != nil }

    init(
        id: UUID = UUID(),
        title: String,
        timestamp: TimeInterval,
        createdAt: Date = Date(),
        audioURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.audioURL = audioURL
    }
}

// MARK: - View Model

@Observable
class WatchViewModel: NSObject, WCSessionDelegate {
    /// Local cache of bookmarks created from the watch this session. Used to
    /// derive generic titles like `Bookmark #3` and to drive the local list
    /// view without waiting for a round-trip from the iPhone.
    var bookmarks: [WatchBookmark] = []


    var isPlaying: Bool = false
    var title: String = "No track selected"
    var thumbnailImage: UIImage? = nil
    var progressFraction: Double = 0.0
    var totalProgressFraction: Double = 0.0
    var totalBookDuration: Double = 0
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
    var watchQuickBookmarkTimeoutSeconds: Int = AppGroupDefaults.watchQuickBookmarkTimeoutSeconds

    var page1Slots: [WatchAction] = [.empty, .empty, .skipBackward, .playPause, .skipForward]
    var page2Slots: [WatchAction] = [.loopMode, .empty, .speed, .sleepTimer, .bookmark]

    // Progress indicator configuration (synced from iPhone)
    var linearBarMode: String = "total"
    var linearBarHidden: Bool = false
    var circularRingMode: String = "chapter"
    var circularRingHidden: Bool = false

    let availableSpeeds: [Double] = [1.0, 1.25, 1.5, 2.0]
    var currentSpeedIndex: Int = 0
    var playbackSpeed: Double { availableSpeeds[currentSpeedIndex] }

    @ObservationIgnored private let defaults = AppGroupDefaults.shared

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
        if let storedSpeed = defaults.object(forKey: "playbackSpeed") as? Double,
           let idx = availableSpeeds.firstIndex(where: { abs($0 - storedSpeed) < 0.001 }) {
            currentSpeedIndex = idx
        }
        bookmarkStorageKey = defaults.string(forKey: "bookmarkStorageKey")
        folderKey = defaults.string(forKey: "folderKey")
        trackId = defaults.string(forKey: "trackId")
        crownAction = defaults.string(forKey: "crownAction") ?? "volume"

        if let thumbnailData = defaults.data(forKey: "thumbnailData"),
           let image = UIImage(data: thumbnailData) {
            thumbnailImage = image
        }

        if let raw = defaults.string(forKey: "watchPage1") {
            page1Slots = padded(parseSlots(raw))
        }
        if let raw = defaults.string(forKey: "watchPage2") {
            page2Slots = padded(parseSlots(raw))
        }

        linearBarMode = AppGroupDefaults.linearBarMode
        linearBarHidden = AppGroupDefaults.linearBarHidden
        circularRingMode = AppGroupDefaults.circularRingMode
        circularRingHidden = AppGroupDefaults.circularRingHidden
    }

    private func parseSlots(_ raw: String) -> [WatchAction] {
        WatchSlotConfiguration.actions(from: raw)
    }

    private func padded(_ slots: [WatchAction]) -> [WatchAction] {
        WatchSlotConfiguration.padded(slots)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else {
            if let error {
                print("WatchConnectivity activation failed: \(error)")
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
        DispatchQueue.main.async {
            let previousTrackId = self.trackId

            if let crownAction = state["crownAction"] as? String {
                self.crownAction = crownAction
                self.defaults.set(crownAction, forKey: "crownAction")
            }
            if let isHapticEnabled = state["isHapticFeedbackEnabled"] as? Bool {
                AppGroupDefaults.isHapticFeedbackEnabled = isHapticEnabled
            }
            if let timeoutSeconds = state["watchQuickBookmarkTimeoutSeconds"] as? Int {
                let safeTimeout = max(1, timeoutSeconds)
                self.watchQuickBookmarkTimeoutSeconds = safeTimeout
                AppGroupDefaults.watchQuickBookmarkTimeoutSeconds = safeTimeout
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
            if let watchPage1 = state["watchPage1"] as? String {
                self.page1Slots = self.padded(self.parseSlots(watchPage1))
                self.defaults.set(watchPage1, forKey: "watchPage1")
            }
            if let watchPage2 = state["watchPage2"] as? String {
                self.page2Slots = self.padded(self.parseSlots(watchPage2))
                self.defaults.set(watchPage2, forKey: "watchPage2")
            }
            if let linearBarMode = state["linearBarMode"] as? String {
                self.linearBarMode = linearBarMode
                AppGroupDefaults.linearBarMode = linearBarMode
            }
            if let linearBarHidden = state["linearBarHidden"] as? Bool {
                self.linearBarHidden = linearBarHidden
                AppGroupDefaults.linearBarHidden = linearBarHidden
            }
            if let circularRingMode = state["circularRingMode"] as? String {
                self.circularRingMode = circularRingMode
                AppGroupDefaults.circularRingMode = circularRingMode
            }
            if let circularRingHidden = state["circularRingHidden"] as? Bool {
                self.circularRingHidden = circularRingHidden
                AppGroupDefaults.circularRingHidden = circularRingHidden
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
            if state["commandResult"] as? String == "bookmarkJump" {
                WKInterfaceDevice.current().play(.success)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "Orbit_Audiobooks_Widget")
        }
    }

    func requestCurrentState() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["command": "requestState"], replyHandler: { [weak self] reply in
            self?.applyState(reply)
        }, errorHandler: { error in
            print("Error requesting state: \(error)")
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

        var didSend = false
        if session.activationState == .activated, session.isReachable {
            var message: [String: Any] = ["command": command]
            if let params = params {
                for (key, value) in params {
                    message[key] = value
                }
            }
            session.sendMessage(message, replyHandler: { [weak self] reply in
                self?.applyState(reply)
                if Self.isDirectionalCommand(command),
                   self?.loopMode == "bookmark",
                   reply["commandResult"] as? String != "bookmarkJump" {
                    WKInterfaceDevice.current().play(Self.isForwardCommand(command) ? .directionUp : .directionDown)
                }
            }, errorHandler: { [weak self] error in
                print("Error sending command: \(error)")
                self?.requestCurrentState()
            })
            didSend = true
        }

        guard didSend else {
            requestCurrentState()
            return false
        }

        if loopMode == "bookmark" && Self.isDirectionalCommand(command) {
            return true
        }

        if AppGroupDefaults.isHapticFeedbackEnabled {
            switch command {
            case "play", "pause", "toggle":
                WKInterfaceDevice.current().play(.click)
            case "next", "skipForward":
                WKInterfaceDevice.current().play(.directionUp)
            case "skipBackward", "previous":
                WKInterfaceDevice.current().play(.directionDown)
            default:
                WKInterfaceDevice.current().play(.click)
            }
        }

        return true
    }

    /// Trigger the action for a tapped slot, with local state echoes for
    /// playPause / loopMode so the UI feels instant.
    func handle(_ action: WatchAction) {
        switch action {
        case .empty:
            return
        case .playPause:
            if sendCommand(isPlaying ? "pause" : "play") {
                isPlaying.toggle()
            }
        case .loopMode:
            sendCommand("cycleLoopMode")
        case .speed:
            cycleSpeed()
        default:
            sendCommand(action.command)
        }
    }

    // MARK: Sleep Timer (watch -> iPhone)

    func setSleepTimerMinutes(_ minutes: Int) {
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
        sleepTimerMode = "endOfChapter"
        sleepTimerMinutes = 0
        sleepTimerRemainingSeconds = 0
        sendCommand("setSleepTimer", params: [
            "sleepTimerMode": "endOfChapter"
        ])
    }

    func cancelSleepTimer() {
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
        WKInterfaceDevice.current().play(.success)
    }

    func queueVoiceBookmark(fileURL: URL) async throws {
        var metadata = try bookmarkPayload(command: "addWatchVoiceBookmark")
        metadata["voiceMemoFileName"] = fileURL.lastPathComponent
        metadata["voiceMemoData"] = try await Task.detached {
            try Data(contentsOf: fileURL)
        }.value

        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(metadata, replyHandler: nil) { error in
                print("Immediate voice bookmark send failed: \(error)")
                WCSession.default.transferUserInfo(metadata)
            }
        } else {
            session.transferUserInfo(metadata)
        }
        WKInterfaceDevice.current().play(.success)
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
            print("Quick bookmark failed: \(error.localizedDescription)")
            WKInterfaceDevice.current().play(.failure)
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

private enum WatchBookmarkError: LocalizedError {
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

// MARK: - Watch Voice Memo Recorder

@Observable
final class WatchVoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    static let maximumDuration: TimeInterval = 30

    private(set) var isRecording: Bool = false
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var recordingURL: URL?

    func startRecording() throws {
        let directory = try Self.recordingsDirectory()
        let fileURL = directory.appendingPathComponent("watch-memo-\(UUID().uuidString).m4a")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.prepareToRecord()
        audioRecorder.record(forDuration: Self.maximumDuration)

        recorder = audioRecorder
        recordingURL = fileURL
        elapsed = 0
        isRecording = true
        startTimer()
    }

    @discardableResult
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recordingURL
    }

    func discardRecording() {
        if isRecording {
            _ = stopRecording()
        }
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        elapsed = 0
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = min(recorder.currentTime, Self.maximumDuration)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            self.elapsed = min(recorder.currentTime, Self.maximumDuration)
            if self.elapsed >= Self.maximumDuration {
                _ = self.stopRecording()
            }
        }
    }

    private static func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchVoiceMemos", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }
}

// MARK: - Accessibility Helper

private struct ToggleTraitModifier: ViewModifier {
    let isToggle: Bool
    let value: String?

    func body(content: Content) -> some View {
        if isToggle {
            content
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(value ?? "")
        } else {
            content
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = WatchViewModel()
    @State private var crownAccumulator: Double = 0.0
    @State private var previousCrownOffset: Double = 0.0
    @State private var selectedPage: Int = 0
    @State private var isShowingNewBookmark = false
    @State private var isShowingSleepTimer = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Blurred background derived from the artwork (preserved from blueprint)
            if let image = viewModel.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.6))
            } else {
                Color.black.ignoresSafeArea()
            }

            TabView(selection: $selectedPage) {
                PlayerPage(
                    slots: viewModel.page1Slots,
                    viewModel: viewModel,
                    onBookmark: { isShowingNewBookmark = true },
                    onSleepTimer: { isShowingSleepTimer = true }
                )
                    .tag(0)
                PlayerPage(
                    slots: viewModel.page2Slots,
                    viewModel: viewModel,
                    onBookmark: { isShowingNewBookmark = true },
                    onSleepTimer: { isShowingSleepTimer = true }
                )
                    .tag(1)
            }
            .tabViewStyle(.page)
        }
        .focusable(true, interactions: .edit)
        .focused($isFocused)
        .defaultFocus($isFocused, true)
        .digitalCrownRotation($crownAccumulator) { event in
            handleCrownRotation(offset: event.offset)
        }
        .sheet(isPresented: $isShowingNewBookmark) {
            NewBookmarkView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingSleepTimer) {
            SleepTimerView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.requestCurrentState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.requestCurrentState()
        }
    }

    private func handleCrownRotation(offset: Double) {
        let delta = offset - previousCrownOffset
        previousCrownOffset = offset
        guard delta != 0 else { return }

        if viewModel.crownAction == "scrub" {
            viewModel.sendCommand("scrubDelta", params: ["delta": delta])
        } else {
            viewModel.sendCommand("volumeDelta", params: ["delta": delta])
        }
    }
}

// MARK: - Player Page (per-page layout matching the blueprint)
//
// Layout invariants (from the blueprint / "Source of Truth"):
//   • Artwork is centered horizontally, ~80×80, rounded.
//   • The chapter / track title sits directly under the artwork with its own
//     horizontal padding — NOTHING is allowed to overlap it.
//   • Top-left / top-right slot buttons are anchored to the very top of the
//     screen (in line with the system clock area), which guarantees clear
//     breathing room between them and the title below the artwork.
//   • The 3-button transport row sits at the bottom with the large play
//     control (with progress ring) in the middle.

private struct PlayerPage: View {
    let slots: [WatchAction]
    let viewModel: WatchViewModel
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    var body: some View {
        ZStack {
            // Main vertical content (artwork + title + progress bar + transport row)
            VStack(spacing: 8) {
                if let image = viewModel.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.title)
                                .foregroundColor(.white)
                        )
                }

                Text(viewModel.title)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal)
                
                // Linear progress bar (configurable mode + visibility)
                if !viewModel.linearBarHidden {
                    let linearProgress = viewModel.linearBarMode == "chapter"
                        ? viewModel.progressFraction
                        : viewModel.totalProgressFraction
                    ProgressView(value: linearProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.green)
                        .padding(.horizontal, 16)
                        .scaleEffect(y: 0.5) // Thin bar
                        .animation(viewModel.progressAnimationSuppressed ? nil : .linear(duration: 0.5), value: linearProgress)
                }

                TransportRow(
                    leftSlot: slots[2],
                    centerSlot: slots[3],
                    rightSlot: slots[4],
                    viewModel: viewModel,
                    onBookmark: onBookmark,
                    onSleepTimer: onSleepTimer
                )
                .padding(.top, 6)
            }
            
            // Top-row slots
            VStack {
                HStack {
                    TopSlotButton(action: slots[0], viewModel: viewModel, onBookmark: onBookmark, onSleepTimer: onSleepTimer)
                        .padding(.leading, 8)
                    Spacer()
                    TopSlotButton(action: slots[1], viewModel: viewModel, onBookmark: onBookmark, onSleepTimer: onSleepTimer)
                        .padding(.trailing, 8)
                }
                .padding(.top, 8)
                Spacer()
            }
        }
    }
}

// MARK: - Top slot button (small, top-row chrome)

private struct TopSlotButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    var body: some View {
        if action == .empty {
            EmptyView()
        } else {
            Button {
                if action == .bookmark {
                    onBookmark()
                } else if action == .sleepTimer {
                    onSleepTimer()
                } else {
                    viewModel.handle(action)
                }
            } label: {
                Group {
                    if action == .loopMode && viewModel.loopMode == "bookmark" {
                        ZStack {
                            Image(systemName: "arrow.trianglehead.clockwise")
                                .font(.system(size: 24))
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 8, weight: .bold))
                        }
                    } else if action == .speed {
                        Text(formatSpeed(viewModel.playbackSpeed))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    } else if action == .sleepTimer {
                        ZStack {
                            Image(systemName: viewModel.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(viewModel.isSleepTimerActive ? Color.accentColor : Color.white)
                            if viewModel.sleepTimerMode == "minutes" && viewModel.sleepTimerRemainingSeconds > 0 {
                                Text(sleepCountdownText(viewModel.sleepTimerRemainingSeconds))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.accentColor)
                                    .monospacedDigit()
                                    .offset(y: 16)
                            }
                        }
                    } else {
                        Image(systemName: iconName)
                            .font(.system(size: 24))
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabelText)
            .modifier(ToggleTraitModifier(isToggle: action == .loopMode, value: action == .loopMode ? loopModeAccessibilityValue : nil))
        }
    }

    private var loopModeAccessibilityValue: String {
        switch viewModel.loopMode {
        case "chapter": return "Chapter"
        case "bookmark": return "Bookmark"
        default: return "Off"
        }
    }

    private var iconName: String {
        if action == .loopMode {
            switch viewModel.loopMode {
            case "chapter": return "infinity.circle.fill"
            case "bookmark": return "arrow.trianglehead.clockwise"
            default: return "infinity.circle"
            }
        }
        return action.iconName
    }

    private var accessibilityLabelText: String {
        switch action {
        case .playPause: return viewModel.isPlaying ? "Pause" : "Play"
        case .skipForward: return "Skip forward 30 seconds"
        case .skipBackward: return "Skip back 30 seconds"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .loopMode: return "Loop mode"
        case .speed: return "Playback speed"
        case .sleepTimer: return "Sleep timer"
        case .bookmark: return "Bookmark"
        case .empty: return ""
        }
    }
}

fileprivate func sleepCountdownText(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 {
        let h = s / 3600
        let m = (s % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }
    let m = s / 60
    let sec = s % 60
    return String(format: "%d:%02d", m, sec)
}

// MARK: - Sleep Timer Sheet

private struct SleepTimerView: View {
    let viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    timerButton(label: "15 Minutes", systemImage: "15.circle", isOn: isMinutes(15)) {
                        viewModel.setSleepTimerMinutes(15); dismiss()
                    }
                    timerButton(label: "30 Minutes", systemImage: "30.circle", isOn: isMinutes(30)) {
                        viewModel.setSleepTimerMinutes(30); dismiss()
                    }
                    timerButton(label: "45 Minutes", systemImage: "45.circle", isOn: isMinutes(45)) {
                        viewModel.setSleepTimerMinutes(45); dismiss()
                    }
                    timerButton(label: "1 Hour", systemImage: "1.circle", isOn: isMinutes(60)) {
                        viewModel.setSleepTimerMinutes(60); dismiss()
                    }
                }
                Section {
                    timerButton(label: "End of Chapter", systemImage: "book.closed", isOn: viewModel.sleepTimerMode == "endOfChapter") {
                        viewModel.setSleepTimerEndOfChapter(); dismiss()
                    }
                }
                if viewModel.isSleepTimerActive {
                    Section {
                        Button(role: .destructive) {
                            viewModel.cancelSleepTimer(); dismiss()
                        } label: {
                            Label("Off", systemImage: "xmark.circle")
                        }
                    } footer: {
                        if viewModel.sleepTimerMode == "minutes" {
                            Text("Remaining: \(sleepCountdownText(viewModel.sleepTimerRemainingSeconds))")
                        }
                    }
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }

    private func isMinutes(_ m: Int) -> Bool {
        viewModel.sleepTimerMode == "minutes" && viewModel.sleepTimerMinutes == m
    }

    @ViewBuilder
    private func timerButton(label: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

fileprivate func formatSpeed(_ speed: Double) -> String {
    let formatted: String
    if speed.truncatingRemainder(dividingBy: 1) == 0 {
        formatted = String(format: "%.0f", speed)
    } else {
        formatted = String(speed)
    }
    return "\(formatted)x"
}

// MARK: - Bottom transport row (left button | play+ring | right button)

private struct TransportRow: View {
    let leftSlot: WatchAction
    let centerSlot: WatchAction
    let rightSlot: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            SideTransportButton(action: leftSlot, viewModel: viewModel, onBookmark: onBookmark, onSleepTimer: onSleepTimer)

            CenterTransportButton(action: centerSlot, viewModel: viewModel, onBookmark: onBookmark, onSleepTimer: onSleepTimer)

            SideTransportButton(action: rightSlot, viewModel: viewModel, onBookmark: onBookmark, onSleepTimer: onSleepTimer)
        }
    }
}

private struct SideTransportButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    var body: some View {
        Button {
            if action == .bookmark {
                onBookmark()
            } else if action == .sleepTimer {
                onSleepTimer()
            } else {
                viewModel.handle(action)
            }
        } label: {
            Group {
                if action == .loopMode && viewModel.loopMode == "bookmark" {
                    ZStack {
                        Image(systemName: "arrow.trianglehead.clockwise")
                            .font(.system(size: 20))
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                } else if action == .speed {
                    Text(formatSpeed(viewModel.playbackSpeed))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else if action == .sleepTimer {
                    ZStack {
                        Image(systemName: viewModel.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(viewModel.isSleepTimerActive ? Color.accentColor : Color.white)
                        if viewModel.sleepTimerMode == "minutes" && viewModel.sleepTimerRemainingSeconds > 0 {
                            Text(sleepCountdownText(viewModel.sleepTimerRemainingSeconds))
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                                .monospacedDigit()
                                .offset(y: 14)
                        }
                    }
                } else {
                    Image(systemName: sideIconName)
                        .font(.system(size: 20))
                }
            }
            .frame(width: 38, height: 38)
            .padding(15)
            .contentShape(Rectangle())
            .opacity(action == .empty ? 0.35 : 1.0)
        }
        .buttonStyle(.borderedProminent)
        .disabled(action == .empty)
        .accessibilityLabel(accessibilityLabelText)
        .modifier(ToggleTraitModifier(isToggle: action == .loopMode, value: action == .loopMode ? loopModeAccessibilityValue : nil))
    }

    private var sideIconName: String {
        if action == .loopMode {
            switch viewModel.loopMode {
            case "chapter": return "infinity.circle.fill"
            case "bookmark": return "arrow.trianglehead.clockwise"
            default: return "infinity.circle"
            }
        }
        return action == .empty ? "plus" : action.iconName
    }

    private var loopModeAccessibilityValue: String {
        switch viewModel.loopMode {
        case "chapter": return "Chapter"
        case "bookmark": return "Bookmark"
        default: return "Off"
        }
    }

    private var accessibilityLabelText: String {
        switch action {
        case .playPause: return viewModel.isPlaying ? "Pause" : "Play"
        case .skipForward: return "Skip forward 30 seconds"
        case .skipBackward: return "Skip back 30 seconds"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .loopMode: return "Loop mode"
        case .speed: return "Playback speed"
        case .sleepTimer: return "Sleep timer"
        case .bookmark: return "Bookmark"
        case .empty: return "Empty slot"
        }
    }
}

private struct CenterTransportButton: View {
    let action: WatchAction
    let viewModel: WatchViewModel
    let onBookmark: () -> Void
    let onSleepTimer: () -> Void

    var body: some View {
        ZStack {
            if !viewModel.circularRingHidden {
                let ringProgress = viewModel.circularRingMode == "total"
                    ? viewModel.totalProgressFraction
                    : viewModel.progressFraction
                // Use the suppression flag matching whichever progress source the ring tracks.
                let ringSuppressed = viewModel.circularRingMode == "chapter"
                    ? viewModel.ringAnimationSuppressed
                    : viewModel.progressAnimationSuppressed
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 4)
                    .frame(width: 52, height: 52)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(-90))
                    .animation(ringSuppressed ? nil : .linear(duration: 0.5), value: ringProgress)
            }

            Button {
                if resolvedAction == .bookmark {
                    onBookmark()
                } else if resolvedAction == .sleepTimer {
                    onSleepTimer()
                } else {
                    viewModel.handle(resolvedAction)
                }
            } label: {
                Image(systemName: centerIconName)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(resolvedAction == .playPause ? (viewModel.isPlaying ? "Pause" : "Play") : resolvedAction.iconName)

            // Hidden helper for the double-tap primary-action shortcut.
            Button("") {
                if resolvedAction == .bookmark {
                    onBookmark()
                } else if resolvedAction == .sleepTimer {
                    onSleepTimer()
                } else {
                    viewModel.handle(resolvedAction)
                }
            }
            .opacity(0)
            .handGestureShortcut(.primaryAction)
        }
    }

    /// If the designer left the center slot empty, keep the play/pause control
    /// (the blueprint's hero element) so the UI is never broken.
    private var resolvedAction: WatchAction {
        action == .empty ? .playPause : action
    }

    private var centerIconName: String {
        switch resolvedAction {
        case .playPause:
            return viewModel.isPlaying ? "pause.fill" : "play.fill"
        default:
            return resolvedAction.iconName
        }
    }
}

// MARK: - New Bookmark

private struct NewBookmarkView: View {
    let viewModel: WatchViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = WatchVoiceMemoRecorder()
    @State private var alertMessage = ""
    @State private var isShowingAlert = false
    @State private var quickBookmarkTimer: Timer?
    @State private var quickBookmarkStartedAt = Date()
    @State private var quickBookmarkRemaining: TimeInterval = 0
    @State private var didCompleteQuickBookmark = false

    private var recordingProgress: Double {
        min(recorder.elapsed / WatchVoiceMemoRecorder.maximumDuration, 1)
    }

    private var quickBookmarkTimeout: TimeInterval {
        TimeInterval(max(1, viewModel.watchQuickBookmarkTimeoutSeconds))
    }

    private var quickBookmarkProgress: Double {
        guard quickBookmarkTimeout > 0 else { return 0 }
        return min(max(quickBookmarkRemaining / quickBookmarkTimeout, 0), 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: recorder.isRecording ? recordingProgress : quickBookmarkProgress)
                        .stroke(recorder.isRecording ? .red : Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: recorder.isRecording ? "stop.fill" : "bookmark.fill")
                        .font(.title3)
                        .foregroundStyle(recorder.isRecording ? .red : .primary)
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

                Text(recorder.isRecording ? recordingDurationText : quickBookmarkCountdownText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Primary, low-friction "Quick Bookmark" action. Bypasses the
                // microphone entirely and inserts a generic bookmark with a
                // title derived from the current bookmarks count.
                if !recorder.isRecording {
                    Button {
                        cancelQuickBookmarkTimer()
                        viewModel.addQuickBookmark()
                        WKInterfaceDevice.current().play(.success)
                        dismiss()
                    } label: {
                        Label("Quick Bookmark", systemImage: "bookmark.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Adds Bookmark #\(viewModel.bookmarks.count + 1) without recording audio")
                }

                Button {
                    recorder.isRecording ? saveVoiceMemo() : startVoiceBookmark()
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Record Note", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(recorder.isRecording ? .red : .accentColor)
            }

            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle("New Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        cancelQuickBookmarkTimer()
                        recorder.discardRecording()
                        dismiss()
                    }
                }
            }
            .alert("Bookmark Not Saved", isPresented: $isShowingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onChange(of: recorder.isRecording) { oldValue, newValue in
                if oldValue, !newValue, recorder.elapsed >= WatchVoiceMemoRecorder.maximumDuration {
                    saveVoiceMemo()
                }
            }
            .onAppear {
                startQuickBookmarkTimer()
            }
            .onDisappear {
                cancelQuickBookmarkTimer()
                if recorder.isRecording {
                    _ = recorder.stopRecording()
                }
            }
        }
    }

    private var recordingDurationText: String {
        "\(Int(recorder.elapsed.rounded(.down)))s / \(Int(WatchVoiceMemoRecorder.maximumDuration))s"
    }

    private var quickBookmarkCountdownText: String {
        "\(max(0, Int(quickBookmarkRemaining.rounded(.up))))s"
    }

    private func startQuickBookmarkTimer() {
        quickBookmarkRemaining = quickBookmarkTimeout
        quickBookmarkStartedAt = Date()
        quickBookmarkTimer?.invalidate()
        quickBookmarkTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            guard !recorder.isRecording, !didCompleteQuickBookmark else { return }
            let elapsed = Date().timeIntervalSince(quickBookmarkStartedAt)
            let remaining = max(0, quickBookmarkTimeout - elapsed)
            quickBookmarkRemaining = remaining
            if remaining <= 0 {
                completeQuickBookmarkFromTimeout()
            }
        }
        if let quickBookmarkTimer {
            RunLoop.main.add(quickBookmarkTimer, forMode: .common)
        }
    }

    private func cancelQuickBookmarkTimer() {
        quickBookmarkTimer?.invalidate()
        quickBookmarkTimer = nil
    }

    private func completeQuickBookmarkFromTimeout() {
        guard !didCompleteQuickBookmark else { return }
        didCompleteQuickBookmark = true
        cancelQuickBookmarkTimer()
        viewModel.addQuickBookmark()
        dismiss()
    }

    private func startVoiceBookmark() {
        cancelQuickBookmarkTimer()
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showAlert("Microphone access is denied. Enable microphone access for Orbit Audiobooks in Settings.")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { isGranted in
                Task { @MainActor in
                    isGranted ? beginRecording() : showAlert("Microphone access is required to record a voice bookmark.")
                }
            }
        @unknown default:
            showAlert("Microphone access is unavailable.")
        }
    }

    private func beginRecording() {
        if viewModel.sendCommand("pause") {
            viewModel.isPlaying = false
        }

        do {
            try recorder.startRecording()
            WKInterfaceDevice.current().play(.start)
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func saveVoiceMemo() {
        cancelQuickBookmarkTimer()
        guard let fileURL = recorder.stopRecording() else {
            showAlert("No recording was captured.")
            return
        }

        Task {
            do {
                try await viewModel.queueVoiceBookmark(fileURL: fileURL)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    recorder.discardRecording()
                    showAlert(error.localizedDescription)
                }
            }
        }
    }

    private func showAlert(_ message: String) {
        alertMessage = message
        isShowingAlert = true
    }
}

#Preview {
    ContentView()
}
