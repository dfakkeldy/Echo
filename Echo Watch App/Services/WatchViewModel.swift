// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit
import os.log

nonisolated private struct WatchConnectivityDictionary: @unchecked Sendable {
    let value: [String: Any]
}

nonisolated private struct WatchConnectivityReplyHandler: @unchecked Sendable {
    let value: ([String: Any]) -> Void

    func callAsFunction(_ response: [String: Any]) {
        value(response)
    }
}

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

    // Pomodoro Timer State
    var pomodoroActive: Bool = false
    var pomodoroDuration: TimeInterval = 25 * 60
    var pomodoroRemaining: TimeInterval = 25 * 60
    @ObservationIgnored private var pomodoroTimer: Timer?
    @ObservationIgnored private var lastPomodoroTick: Date?
    @ObservationIgnored private var alarmHapticsTask: Task<Void, Never>?
    var artworkAccentColorHex: String? = nil
    var artworkAccentColor: Color? {
        guard let hex = artworkAccentColorHex else { return nil }
        return Color(hex: hex)
    }

    var coverRampTopHex: String? = nil
    var coverRampBottomHex: String? = nil

    /// The cover's room, for surfaces that would otherwise be flat black. Nil
    /// for a neutral cover or before the first state reply lands, so callers
    /// keep the black they already had — on an OLED watch that costs no power
    /// and is the right answer, not a placeholder.
    var coverRampGradient: LinearGradient? {
        guard let top = coverRampTopHex.flatMap({ Color(hex: $0) }),
            let bottom = coverRampBottomHex.flatMap({ Color(hex: $0) })
        else { return nil }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

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

    /// Interior chapter/track boundaries as fractions of the whole book,
    /// synced from the iPhone for the segmented progress indicators.
    var bookBoundaryFractions: [Double] = []

    // MARK: Crown volume mirror
    /// Local mirror of the iPhone's app-level output gain in dB. Updated
    /// optimistically while the crown turns, reconciled from state replies.
    var outputGainDB: Double = 0
    var crownVolumeSensitivity: Double = WatchCrownVolume.defaultSensitivity
    /// While the user is actively turning the crown, incoming state snapshots
    /// carry a gain that lags the optimistic local value; skip applying them
    /// until this deadline passes so the indicator doesn't stutter backwards.
    @ObservationIgnored private var volumeAdjustmentActiveUntil: Date = .distantPast
    /// Freshest authoritative gain skipped during the gesture window. Applied
    /// once the window expires, so a rare local/phone divergence (batched
    /// clamping near the rails, or a dropped send) heals in ~1 s instead of
    /// waiting for the next full state sync.
    @ObservationIgnored private var pendingRemoteGainDB: Double?
    @ObservationIgnored private var gainReconcileTask: Task<Void, Never>?

    var volumeFraction: Double { WatchCrownVolume.fraction(forGainDB: outputGainDB) }

    /// Applies a crown rotation delta to the local gain mirror using the same
    /// formula the iPhone applies authoritatively. Returns `true` when the
    /// change crossed a haptic step threshold (the caller plays the haptic).
    func applyLocalVolumeDelta(_ delta: Double) -> Bool {
        let newGain = WatchCrownVolume.applying(
            delta: delta, sensitivity: crownVolumeSensitivity, to: outputGainDB)
        let crossedStep = WatchCrownVolume.crossesHapticStep(from: outputGainDB, to: newGain)
        outputGainDB = newGain
        volumeAdjustmentActiveUntil = Date().addingTimeInterval(1.0)
        return crossedStep
    }

    func playCrownStepHaptic() { playHaptic(.click) }
    func playScrubEngageHaptic() { playHaptic(.start) }

    /// Applies the stashed authoritative gain once the gesture window expires.
    /// The window deadline keeps moving while the crown turns, so the task
    /// re-sleeps until it truly lapses (a MainActor Task, not a Timer, per the
    /// Swift 6 strict-concurrency convention used elsewhere in this type).
    private func scheduleGainReconciliation() {
        gainReconcileTask?.cancel()
        gainReconcileTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = self.volumeAdjustmentActiveUntil.timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(remaining + 0.05))
            }
            guard !Task.isCancelled, let self else { return }
            if let pending = self.pendingRemoteGainDB {
                self.outputGainDB = pending
                self.pendingRemoteGainDB = nil
            }
            self.gainReconcileTask = nil
        }
    }

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
    var linearBarMode: String = "chapter"
    var linearBarHidden: Bool = false
    var circularRingMode: String = "total"
    var circularRingHidden: Bool = false
    var watchArtworkLayout: String = "classic"
    var watchBackgroundStyle: String = "artwork"
    var watchTitleScrollEnabled: Bool = false
    var watchTitleScrollSpeed: Double = 30.0
    var watchDateEnabled: Bool = true
    var watchDateFormat: String = "auto"

    /// Top words for the current chapter, received from the iPhone.
    var currentWordCloud: [WordFrequency] = []

    let availableSpeeds: [Double] = [1.0, 1.25, 1.5, 2.0, 3.0]
    var currentSpeedIndex: Int = 0
    var playbackSpeed: Double { availableSpeeds[currentSpeedIndex] }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reloadWidget: @MainActor () -> Void
    @ObservationIgnored private var wakeRefreshPolicy = WatchWakeRefreshPolicy()
    @ObservationIgnored private var stateRecencyPolicy: WatchStateRecencyPolicy

    /// Retry budget for a failed `requestState` pull, replenished on each wake.
    /// The wake-time pull is the only convergence path that doesn't depend on
    /// the phone noticing reachability, and its sendMessage commonly fails
    /// with "not reachable" in the first seconds after the watch app wakes —
    /// a single log-only failure left the UI frozen on persisted state until
    /// the user pressed a transport button.
    @ObservationIgnored private var stateRequestRetriesRemaining = 0
    @ObservationIgnored private var stateRequestRetryTask: Task<Void, Never>?
    private static let maxStateRequestRetries = 3
    @ObservationIgnored private var scrubReloadCoordinator = WatchWidgetScrubReloadCoordinator()

    /// Plays a haptic only when the user has haptic feedback enabled in settings.
    /// Centralises the gate so individual call sites don't repeat the check.
    private func playHaptic(_ type: WKHapticType) {
        guard defaults.bool(forKey: "isHapticFeedbackEnabled") else { return }
        WKInterfaceDevice.current().play(type)
    }

    func playReviewRevealHaptic() {
        playHaptic(Self.hapticType(for: .reveal))
    }

    private static func hapticType(for feedback: WatchReviewFeedback) -> WKHapticType {
        switch feedback {
        case .reveal:
            return .click
        case .again:
            return .retry
        case .remembered:
            return .success
        }
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
        rollbackTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.rollback()
                self?.requestCurrentState()
            }
        }
    }

    private func updatePlaybackTimer() {
        if isPlaying {
            if playbackTimer == nil {
                lastTimerTick = Date()
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                    [weak self] _ in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.tickPlayback()
                    }
                }
                // Keep the elapsed-time tick firing while the user scrolls / turns the
                // Digital Crown — the default run-loop mode is paused during UI tracking.
                if let playbackTimer {
                    RunLoop.main.add(playbackTimer, forMode: .common)
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

        // If the timer was suspended (watch asleep / backgrounded), the first
        // fire on wake can carry minutes of accumulated wall-clock time.
        // Advancing progress by that much would animate through every
        // intermediate value — the "catching up through chapters" glitch.
        // Cap the raw wall-clock delta at 2.0 s (4× the 0.5 s interval).
        // Beyond that, skip the local tick entirely and request a fresh state
        // from the phone, which has the authoritative position.
        let maxExpectedDelta: TimeInterval = 2.0
        guard elapsed <= maxExpectedDelta else {
            logger.debug(
                "Skipping stale timer tick after \(elapsed)s suspension; requesting fresh state")
            requestCurrentState()
            return
        }

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

    override convenience init() {
        self.init(defaults: AppGroupDefaults.shared, migrateStandardDefaults: true)
    }

    init(
        defaults: UserDefaults,
        migrateStandardDefaults: Bool = false,
        reloadWidget: @MainActor @escaping () -> Void = WatchViewModel.reloadWidgetTimeline
    ) {
        self.defaults = defaults
        self.reloadWidget = reloadWidget
        let persistedSequence =
            (defaults.object(forKey: WatchStateRecencyPolicy.persistedSequenceKey) as? NSNumber)?
            .doubleValue
        let persistedArtworkSequence =
            (defaults.object(forKey: WatchStateRecencyPolicy.persistedArtworkSequenceKey)
            as? NSNumber)?
            .doubleValue
        let persistedThumbnailSequence =
            (defaults.object(forKey: WatchStateRecencyPolicy.persistedThumbnailSequenceKey)
            as? NSNumber)?
            .doubleValue
        stateRecencyPolicy = WatchStateRecencyPolicy(
            lastAppliedSequence: persistedSequence,
            latestArtworkSequence: persistedArtworkSequence,
            lastAppliedThumbnailSequence: persistedThumbnailSequence)
        super.init()
        if migrateStandardDefaults {
            AppGroupDefaults.migrateStandardDefaultsIfNeeded()
        }
        loadPersistedState()
        if WCSession.isSupported(),
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        {
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
            let idx = availableSpeeds.firstIndex(where: { abs($0 - storedSpeed) < 0.001 })
        {
            currentSpeedIndex = idx
        }
        bookmarkStorageKey = defaults.string(forKey: "bookmarkStorageKey")
        folderKey = defaults.string(forKey: "folderKey")
        trackId = defaults.string(forKey: "trackId")
        dueCards = WatchReviewQueueStore.load(from: defaults)
        crownAction = defaults.string(forKey: "crownAction") ?? "volume"
        bookBoundaryFractions = (defaults.array(forKey: "bookBoundaryFractions") as? [Double]) ?? []
        outputGainDB = (defaults.object(forKey: "outputGainDB") as? Double) ?? 0
        let storedCrownVolumeSensitivity = defaults.double(forKey: "crownVolumeSensitivity")
        if storedCrownVolumeSensitivity > 0 {
            crownVolumeSensitivity = storedCrownVolumeSensitivity
        }
        seekBackwardDuration = defaults.integer(forKey: "seekBackwardDuration")
        if seekBackwardDuration == 0 { seekBackwardDuration = 30 }
        seekForwardDuration = defaults.integer(forKey: "seekForwardDuration")
        if seekForwardDuration == 0 { seekForwardDuration = 30 }

        if let thumbnailData = defaults.data(forKey: "thumbnailData"),
            let image = UIImage(data: thumbnailData)
        {
            thumbnailImage = image
        }

        artworkAccentColorHex = defaults.string(forKey: "artworkAccentColorHex")
        coverRampTopHex = defaults.string(forKey: "coverRampTopHex")
        coverRampBottomHex = defaults.string(forKey: "coverRampBottomHex")
        let storedPomDuration = defaults.double(forKey: "pomodoroDuration")
        pomodoroDuration = storedPomDuration > 0 ? storedPomDuration : (25 * 60)
        pomodoroRemaining = pomodoroDuration

        if let data = defaults.data(forKey: "watchPage1"),
            let decoded = try? JSONDecoder().decode([WatchAction].self, from: data)
        {
            page1Slots = padded(decoded)
        } else if let raw = defaults.string(forKey: "watchPage1") {
            // Migration from old comma-separated format
            page1Slots = padded(parseSlots(raw))
        }
        if let data = defaults.data(forKey: "watchPage2"),
            let decoded = try? JSONDecoder().decode([WatchAction].self, from: data)
        {
            page2Slots = padded(decoded)
        } else if let raw = defaults.string(forKey: "watchPage2") {
            // Migration from old comma-separated format
            page2Slots = padded(parseSlots(raw))
        }
        if let data = defaults.data(forKey: "watchPage3"),
            let decoded = try? JSONDecoder().decode([WatchAction].self, from: data)
        {
            page3Slots = padded(decoded)
        }
        if let data = defaults.data(forKey: "watchPage4"),
            let decoded = try? JSONDecoder().decode([WatchAction].self, from: data)
        {
            page4Slots = padded(decoded)
        }
        if let data = defaults.data(forKey: "watchPage5"),
            let decoded = try? JSONDecoder().decode([WatchAction].self, from: data)
        {
            page5Slots = padded(decoded)
        }

        linearBarMode = defaults.string(forKey: "linearBarMode") ?? "chapter"
        linearBarHidden = defaults.bool(forKey: "linearBarHidden")
        circularRingMode = defaults.string(forKey: "circularRingMode") ?? "total"
        circularRingHidden = defaults.bool(forKey: "circularRingHidden")
        watchArtworkLayout = defaults.string(forKey: "watchArtworkLayout") ?? "classic"
        watchBackgroundStyle = defaults.string(forKey: "watchBackgroundStyle") ?? "artwork"
        watchTitleScrollEnabled = defaults.bool(forKey: "watchTitleScrollEnabled")
        let storedSpeed = defaults.double(forKey: "watchTitleScrollSpeed")
        watchTitleScrollSpeed = storedSpeed > 0 ? storedSpeed : 30.0
        watchDateEnabled = defaults.object(forKey: "watchDateEnabled") as? Bool ?? true
        watchDateFormat = defaults.string(forKey: "watchDateFormat") ?? "auto"
    }

    private func parseSlots(_ raw: String) -> [WatchAction] {
        raw.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
    }

    private func padded(_ slots: [WatchAction]) -> [WatchAction] {
        var out = Array(slots.prefix(5))
        while out.count < 5 { out.append(.empty) }
        return out
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else {
            if let error {
                Logger(category: "WatchViewModel").error(
                    "WatchConnectivity activation failed: \(error)")
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stateRequestRetriesRemaining = Self.maxStateRequestRetries
            self.requestCurrentState()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Reachability returning is a fresh sync opportunity, so it gets a
            // fresh retry budget like wake and activation do — the phone often
            // reports reachable a beat before it can actually answer.
            self.stateRequestRetriesRemaining = Self.maxStateRequestRetries
            self.requestCurrentState()
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard session.activationState == .activated else { return }
        let payload = WatchConnectivityDictionary(value: applicationContext)
        Task { @MainActor [weak self, payload] in
            self?.applyReceivedApplicationContext(payload.value)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard session.activationState == .activated else { return }
        let payload = WatchConnectivityDictionary(value: message)
        Task { @MainActor [weak self, payload] in
            self?.applyState(payload.value, source: .liveMessage)
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard session.activationState == .activated else {
            replyHandler([:])
            return
        }
        let payload = WatchConnectivityDictionary(value: message)
        let reply = WatchConnectivityReplyHandler(value: replyHandler)
        Task { @MainActor [weak self, payload, reply] in
            self?.applyState(payload.value, source: .liveMessage)
            reply(["handled": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard session.activationState == .activated else { return }
        let payload = WatchConnectivityDictionary(value: userInfo)
        Task { @MainActor [weak self, payload] in
            self?.applyReceivedUserInfo(payload.value)
            // userInfo deliveries can be minutes stale (queued while unreachable).
            // Request the phone's current state so the watch converges to the
            // authoritative position instead of displaying an outdated snapshot.
            self?.requestCurrentState()
        }
    }

    @discardableResult
    private func applyState(
        _ state: [String: Any], source: WatchStateDeliverySource,
        forceWidgetReload: Bool = false,
        reloadOnProgressDiscontinuity: Bool = true
    ) -> Bool {
        guard !state.isEmpty else { return false }
        guard stateRecencyPolicy.shouldApply(state, source: source) else { return false }
        if let sequence = stateRecencyPolicy.lastAppliedSequence {
            defaults.set(sequence, forKey: WatchStateRecencyPolicy.persistedSequenceKey)
        }
        if let sequence = stateRecencyPolicy.latestArtworkSequence {
            defaults.set(sequence, forKey: WatchStateRecencyPolicy.persistedArtworkSequenceKey)
        }
        if let sequence = stateRecencyPolicy.lastAppliedThumbnailSequence {
            defaults.set(sequence, forKey: WatchStateRecencyPolicy.persistedThumbnailSequenceKey)
        }

        let widgetSnapshotDate = Date()
        let projectedProgress = WatchWidgetProgressProjection.read(from: defaults)
            .fraction(at: widgetSnapshotDate)
        let incomingDisplayTitle = (state["title"] as? String).map {
            $0.applyingChapterTruncation(
                enabled: defaults.bool(forKey: "truncateChapterNamesEnabled"))
        }
        let shouldReloadWidgetImmediately = WatchWidgetReloadPolicy.shouldReload(
            state: state,
            currentIsPlaying: isPlaying,
            currentFolderKey: folderKey,
            currentTrackId: trackId,
            currentTitle: title,
            incomingTitle: incomingDisplayTitle,
            currentPlaybackSpeed: playbackSpeed,
            projectedProgressFraction: projectedProgress,
            reloadOnProgressDiscontinuity: reloadOnProgressDiscontinuity,
            currentBookDuration: totalBookDuration,
            currentAccentHex: artworkAccentColorHex,
            currentRampTopHex: coverRampTopHex,
            hasCachedThumbnail: thumbnailImage != nil
                || defaults.data(forKey: "thumbnailData") != nil)

        do {
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
            if let displayTitle = incomingDisplayTitle {
                self.title = displayTitle
                self.defaults.set(displayTitle, forKey: "title")
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
                        self.ringAnimationSuppressed = false
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
                // Anchor the widget's wall-clock projection to this
                // authoritative fraction so timeline entries can keep the
                // Smart Stack bar moving between deliveries.
                WatchWidgetProgressProjection.writeAnchor(widgetSnapshotDate, to: self.defaults)
                if delta > 0.02 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.5))
                        self.progressAnimationSuppressed = false
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
            if let boundaries = state["bookBoundaryFractions"] as? [Double] {
                self.bookBoundaryFractions = boundaries
                self.defaults.set(boundaries, forKey: "bookBoundaryFractions")
            }
            if let sensitivity = state["crownVolumeSensitivity"] as? Double, sensitivity > 0 {
                self.crownVolumeSensitivity = sensitivity
                self.defaults.set(sensitivity, forKey: "crownVolumeSensitivity")
            }
            if let gainDB = state["outputGainDB"] as? Double {
                // Persist always, but only move the visible mirror when the
                // user isn't mid-gesture — replies lag the optimistic value.
                // Mid-gesture values are stashed and applied when the window
                // expires so the phone's authoritative gain always wins.
                self.defaults.set(gainDB, forKey: "outputGainDB")
                if Date() >= self.volumeAdjustmentActiveUntil {
                    self.outputGainDB = gainDB
                    self.pendingRemoteGainDB = nil
                    self.gainReconcileTask?.cancel()
                    self.gainReconcileTask = nil
                } else {
                    self.pendingRemoteGainDB = gainDB
                    self.scheduleGainReconciliation()
                }
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
                let idx = self.availableSpeeds.firstIndex(where: { abs($0 - playbackSpeed) < 0.001 }
                )
            {
                self.currentSpeedIndex = idx
                self.defaults.set(playbackSpeed, forKey: "playbackSpeed")
            }
            if let watchPage1Data = state["watchPage1"] as? Data,
                let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage1Data)
            {
                self.page1Slots = self.padded(decoded)
                self.defaults.set(watchPage1Data, forKey: "watchPage1")
            }
            if let watchPage2Data = state["watchPage2"] as? Data,
                let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage2Data)
            {
                self.page2Slots = self.padded(decoded)
                self.defaults.set(watchPage2Data, forKey: "watchPage2")
            }
            if let watchPage3Data = state["watchPage3"] as? Data,
                let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage3Data)
            {
                self.page3Slots = self.padded(decoded)
                self.defaults.set(watchPage3Data, forKey: "watchPage3")
            }
            if let watchPage4Data = state["watchPage4"] as? Data,
                let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage4Data)
            {
                self.page4Slots = self.padded(decoded)
                self.defaults.set(watchPage4Data, forKey: "watchPage4")
            }
            if let watchPage5Data = state["watchPage5"] as? Data,
                let decoded = try? JSONDecoder().decode([WatchAction].self, from: watchPage5Data)
            {
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
            if let watchTitleScrollEnabled = state["watchTitleScrollEnabled"] as? Bool {
                self.watchTitleScrollEnabled = watchTitleScrollEnabled
                self.defaults.set(watchTitleScrollEnabled, forKey: "watchTitleScrollEnabled")
            }
            if let watchTitleScrollSpeed = state["watchTitleScrollSpeed"] as? Double {
                self.watchTitleScrollSpeed = watchTitleScrollSpeed
                self.defaults.set(watchTitleScrollSpeed, forKey: "watchTitleScrollSpeed")
            }
            if let watchDateEnabled = state["watchDateEnabled"] as? Bool {
                self.watchDateEnabled = watchDateEnabled
                self.defaults.set(watchDateEnabled, forKey: "watchDateEnabled")
            }
            if let watchDateFormat = state["watchDateFormat"] as? String {
                self.watchDateFormat = watchDateFormat
                self.defaults.set(watchDateFormat, forKey: "watchDateFormat")
            }
            if let thumbnailData = state["thumbnailData"] as? Data {
                self.defaults.set(thumbnailData, forKey: "thumbnailData")
                if let image = UIImage(data: thumbnailData) {
                    self.thumbnailImage = image
                }
            } else if state["hasThumbnail"] as? Bool == false
                || (state["trackId"] != nil && self.trackId != previousTrackId)
            {
                // An explicit absence or track change makes the cached image
                // stale. Show the placeholder until a fresh transfer arrives.
                self.defaults.removeObject(forKey: "thumbnailData")
                self.thumbnailImage = nil
            }
            if let accentHex = state["artworkAccentColorHex"] as? String {
                if accentHex.isEmpty {
                    self.artworkAccentColorHex = nil
                    self.defaults.removeObject(forKey: "artworkAccentColorHex")
                } else {
                    self.artworkAccentColorHex = accentHex
                    self.defaults.set(accentHex, forKey: "artworkAccentColorHex")
                }
            } else if state["trackId"] != nil, self.trackId != previousTrackId {
                self.artworkAccentColorHex = nil
                self.defaults.removeObject(forKey: "artworkAccentColorHex")
            }
            // The ramp ends follow the accent's contract exactly: an empty
            // string is an explicit clear, and a track change without the key
            // drops the previous book's room rather than leaving it behind the
            // new one.
            if let topHex = state["coverRampTopHex"] as? String {
                if topHex.isEmpty {
                    self.coverRampTopHex = nil
                    self.defaults.removeObject(forKey: "coverRampTopHex")
                } else {
                    self.coverRampTopHex = topHex
                    self.defaults.set(topHex, forKey: "coverRampTopHex")
                }
            } else if state["trackId"] != nil, self.trackId != previousTrackId {
                self.coverRampTopHex = nil
                self.defaults.removeObject(forKey: "coverRampTopHex")
            }
            if let bottomHex = state["coverRampBottomHex"] as? String {
                if bottomHex.isEmpty {
                    self.coverRampBottomHex = nil
                    self.defaults.removeObject(forKey: "coverRampBottomHex")
                } else {
                    self.coverRampBottomHex = bottomHex
                    self.defaults.set(bottomHex, forKey: "coverRampBottomHex")
                }
            } else if state["trackId"] != nil, self.trackId != previousTrackId {
                self.coverRampBottomHex = nil
                self.defaults.removeObject(forKey: "coverRampBottomHex")
            }
            if let wordCloudJSON = state["wordCloudJSON"] as? String,
                let jsonData = wordCloudJSON.data(using: .utf8),
                let words = try? JSONDecoder().decode([WordFrequency].self, from: jsonData)
            {
                self.currentWordCloud = words
            }

            if let dueCardsJSON = state["dueCardsJSON"] as? String,
                let cards = WatchReviewQueueStore.decode(dueCardsJSON)
            {
                self.dueCards = cards
                WatchReviewQueueStore.save(cards, to: self.defaults)
            }

            if state["commandResult"] as? String == "bookmarkJump" {
                self.playHaptic(.success)
            }
            if shouldReloadWidgetImmediately || forceWidgetReload {
                reloadWidget()
            }
            self.updatePlaybackTimer()
            return true
        }
    }

    static func reloadWidgetTimeline() {
        WidgetCenter.shared.reloadTimelines(ofKind: "Echo_Widget")
    }

    /// Sends a flashcard grade back to iPhone for FSRS processing and persistence.
    func gradeFlashcard(cardID: String, grade: Int) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated else {
            requestCurrentState()
            return
        }

        session.transferUserInfo([
            WatchMessageKey.command: "gradeFlashcard",
            "cardID": cardID,
            "grade": grade,
        ])
        dueCards.removeAll { $0.id == cardID }
        WatchReviewQueueStore.save(dueCards, to: defaults)
        playHaptic(Self.hapticType(for: WatchReviewFeedbackPolicy.feedback(forGrade: grade)))
    }

    @discardableResult
    func applyReceivedApplicationContext(_ applicationContext: [String: Any]) -> Bool {
        guard !applicationContext.isEmpty else { return false }
        return applyState(applicationContext, source: .applicationContext)
    }

    @discardableResult
    func applyReceivedUserInfo(_ userInfo: [String: Any]) -> Bool {
        guard !userInfo.isEmpty else { return false }
        return applyState(userInfo, source: .queuedUserInfo)
    }

    @discardableResult
    func applyReceivedCommandReply(_ reply: [String: Any], command: String) -> Bool {
        guard !reply.isEmpty else { return false }
        return applyState(
            reply,
            source: .liveMessage,
            forceWidgetReload: Self.commandRequiresWidgetReload(command),
            reloadOnProgressDiscontinuity: command != "scrubDelta")
    }

    func finishScrubbing() {
        if scrubReloadCoordinator.gestureDidEnd() {
            reloadWidget()
        }
    }

    private func finishScrubCommand(requiresRecovery: Bool = false) {
        if scrubReloadCoordinator.commandFinished(requiresRecovery: requiresRecovery) {
            reloadWidget()
        }
    }

    private func finishScrubRecovery() {
        if scrubReloadCoordinator.recoveryStateApplied() {
            reloadWidget()
        }
    }

    @discardableResult
    func applyReceivedApplicationContext() -> Bool {
        guard WCSession.isSupported() else { return false }
        return applyReceivedApplicationContext(WCSession.default.receivedApplicationContext)
    }

    @discardableResult
    func requestCurrentState() -> Bool {
        guard WCSession.isSupported() else { return false }

        let session = WCSession.default
        applyReceivedApplicationContext(session.receivedApplicationContext)
        guard session.activationState == .activated else { return false }

        var message: [String: Any] = [WatchMessageKey.command: "requestState"]
        // Report which artwork transfer this watch last applied (0 = none), so
        // the phone can re-offer the current thumbnail when this watch is
        // behind — a lost or purged transferUserInfo is otherwise never
        // retried, because the phone-side dedup remembers having sent it.
        if defaults.data(forKey: "thumbnailData") != nil,
            let heldSequence = stateRecencyPolicy.lastAppliedThumbnailSequence
        {
            message["watchArtworkSeq"] = heldSequence
        } else {
            // No cached image: also drop the applied-thumbnail dedup marker so
            // the phone's re-sent transfer (same artwork sequence) applies
            // instead of being rejected as a duplicate.
            stateRecencyPolicy.forgetAppliedThumbnail()
            defaults.removeObject(forKey: WatchStateRecencyPolicy.persistedThumbnailSequenceKey)
            message["watchArtworkSeq"] = 0.0
        }

        // WatchConnectivity invokes these reply/error handlers on a background
        // serial queue, not the main thread. @Sendable keeps the closures from
        // inheriting this type's MainActor isolation before they can hop back.
        // Mirrors the WCSessionDelegate callbacks above.
        session.sendMessage(
            message,
            replyHandler: { @Sendable reply in
                let payload = WatchConnectivityDictionary(value: reply)
                Task { @MainActor [weak self, payload] in
                    self?.cancelStateRequestRetry()
                    self?.applyState(payload.value, source: .liveMessage)
                    self?.finishScrubRecovery()
                }
            },
            errorHandler: { @Sendable error in
                let errorDescription = error.localizedDescription
                Task { @MainActor [weak self, errorDescription] in
                    guard let self else { return }
                    self.logger.error("Error requesting state: \(errorDescription)")
                    self.scheduleStateRequestRetry()
                }
            })
        return true
    }

    /// Retries a failed state pull after a short delay, bounded per wake by
    /// `maxStateRequestRetries`. Redundant retries are cheap: a duplicate
    /// snapshot is rejected wholesale by the recency policy.
    private func scheduleStateRequestRetry() {
        guard stateRequestRetryTask == nil, stateRequestRetriesRemaining > 0 else { return }
        stateRequestRetriesRemaining -= 1
        stateRequestRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.stateRequestRetryTask = nil
            self.requestCurrentState()
        }
    }

    private func cancelStateRequestRetry() {
        stateRequestRetryTask?.cancel()
        stateRequestRetryTask = nil
    }

    func refreshAfterWake() {
        appWillEnterForeground()
        applyReceivedApplicationContext()
        consumePendingWidgetToggle()
        stateRequestRetriesRemaining = Self.maxStateRequestRetries

        guard wakeRefreshPolicy.canRefresh() else { return }
        guard requestCurrentState() else { return }
        wakeRefreshPolicy.recordRefresh()
    }

    /// Completes the widget play/pause intent's handshake. The widget
    /// extension has no `WCSession`, so `TogglePlaybackIntent` can only
    /// record the desired state and open this app; the app performs the real
    /// transport command once it wakes. The command is absolute
    /// ("play"/"pause", already idempotent on the phone router) so an
    /// authoritative state push landing between tap and consumption can't
    /// cause a double toggle.
    private func consumePendingWidgetToggle() {
        guard let desired = WidgetPlaybackToggleRequest.consume(from: defaults, at: Date())
        else { return }
        isPlaying = desired
        updatePlaybackTimer()
        sendCommand(desired ? "play" : "pause")
    }

    /// Handles a `.backgroundTask(.watchConnectivity)` wake: the system
    /// launched or resumed this app in the background because the phone
    /// pushed WatchConnectivity content. Waits briefly for the session to
    /// finish activating and delivering (the delegate callbacks apply state
    /// as it lands), then applies the latest coalesced application context so
    /// the app-group snapshot — and through it the Smart Stack widget —
    /// reflects the push even though the UI never came to the foreground.
    func drainBackgroundConnectivity() async {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if session.activationState == .activated, !session.hasContentPending { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        applyReceivedApplicationContext()
    }

    private static func isDirectionalCommand(_ command: String) -> Bool {
        command == "next" || command == "previous" || command == "skipForward"
            || command == "skipBackward"
    }

    private static func isForwardCommand(_ command: String) -> Bool {
        command == "next" || command == "skipForward"
    }

    private static func isContinuousCommand(_ command: String) -> Bool {
        command == "volumeDelta" || command == "scrubDelta"
    }

    private static func commandRequiresWidgetReload(_ command: String) -> Bool {
        switch command {
        case "play", "pause", "toggle", "cycleSpeed", "seek", "next", "previous", "nextSection",
            "previousSection", "skipBackward", "skipForward":
            return true
        default:
            return false
        }
    }

    @discardableResult
    func sendCommand(_ command: String, params: [String: Any]? = nil) -> Bool {
        guard !command.isEmpty else { return false }
        let session = WCSession.default
        if command == "scrubDelta" {
            scrubReloadCoordinator.commandSent()
        }

        guard session.activationState == .activated else {
            if command == "scrubDelta" {
                finishScrubCommand(requiresRecovery: true)
            }
            rollback()
            requestCurrentState()
            return false
        }

        var message: [String: Any] = [WatchMessageKey.command: command]
        if let params = params {
            for (key, value) in params {
                message[key] = value
            }
        }
        // WatchConnectivity invokes these reply/error handlers on a background
        // serial queue. @Sendable keeps the closures from inheriting this type's
        // MainActor isolation before they can hop back. Mirrors the
        // WCSessionDelegate callbacks above.
        session.sendMessage(
            message,
            replyHandler: { @Sendable reply in
                let payload = WatchConnectivityDictionary(value: reply)
                Task { @MainActor [weak self, payload] in
                    self?.clearPendingRollback()
                    self?.applyReceivedCommandReply(payload.value, command: command)
                    if command == "scrubDelta" {
                        self?.finishScrubCommand()
                    }
                    if Self.isDirectionalCommand(command),
                        self?.loopMode == "bookmark",
                        payload.value["commandResult"] as? String != "bookmarkJump"
                    {
                        self?.playHaptic(
                            Self.isForwardCommand(command) ? .directionUp : .directionDown)
                    }
                }
            },
            errorHandler: { @Sendable error in
                // Deliberately do NOT fall back to transferUserInfo here. Transport,
                // navigation and seek commands are only meaningful live. transferUserInfo
                // persists them in a FIFO queue that drains (even across launches) the next
                // time the phone is reachable, replaying stale play/pause/seek intent and
                // fighting the user. sendMessage already wakes a suspended companion app; if
                // it still fails the correct recovery is to revert the optimistic UI and
                // re-pull the phone's authoritative state — not to queue a stale command.
                let errorDescription = error.localizedDescription
                Task { @MainActor [weak self, errorDescription] in
                    if command == "scrubDelta" {
                        self?.finishScrubCommand(requiresRecovery: true)
                    }
                    self?.logger.error(
                        "Error sending command \(command): \(errorDescription). Reverting optimistic state."
                    )
                    self?.rollback()
                    self?.requestCurrentState()
                }
            })
        if pendingSnapshot != nil {
            scheduleRollback()
        }

        if loopMode == "bookmark" && Self.isDirectionalCommand(command) {
            return true
        }

        // Continuous crown streams get threshold-based haptics at the call
        // site; a per-message haptic here would buzz on every batched tick.
        if Self.isContinuousCommand(command) {
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
        sendCommand(
            "setSleepTimer",
            params: [
                "sleepTimerMode": "minutes",
                "sleepTimerMinutes": minutes,
            ])
    }

    func setSleepTimerEndOfChapter() {
        prepareOptimisticUpdate()
        sleepTimerMode = "endOfChapter"
        sleepTimerMinutes = 0
        sleepTimerRemainingSeconds = 0
        sendCommand(
            "setSleepTimer",
            params: [
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
            WatchMessageKey.command: command,
            "bookmarkID": UUID().uuidString,
            "bookmarkStorageKey": bookmarkStorageKey,
            "timestamp": max(0, currentTime),
            "createdAt": Date().timeIntervalSince1970,
        ]

        if let folderKey {
            payload["folderKey"] = folderKey
        }
        if let trackId {
            payload["trackId"] = trackId
        }

        return payload
    }

    // MARK: - Pomodoro Timer

    func togglePomodoro() {
        if pomodoroActive {
            stopPomodoro()
        } else {
            startPomodoro()
        }
    }

    func startPomodoro() {
        guard !pomodoroActive else { return }
        if pomodoroRemaining <= 0 {
            pomodoroRemaining = pomodoroDuration
        }
        pomodoroActive = true
        lastPomodoroTick = Date()
        playHaptic(.start)

        pomodoroTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.tickPomodoro()
            }
        }
        // Keep the countdown ticking while the user scrolls / turns the Digital Crown —
        // the default run-loop mode is paused during UI tracking. Matches SleepTimerManager.
        if let pomodoroTimer {
            RunLoop.main.add(pomodoroTimer, forMode: .common)
        }
    }

    func stopPomodoro() {
        guard pomodoroActive else { return }
        pomodoroActive = false
        pomodoroTimer?.invalidate()
        pomodoroTimer = nil
        lastPomodoroTick = nil
        // Silence a ringing alarm if the user stops the Pomodoro mid-alarm.
        alarmHapticsTask?.cancel()
        alarmHapticsTask = nil
        playHaptic(.stop)
    }

    func setPomodoroDuration(_ duration: TimeInterval) {
        stopPomodoro()
        self.pomodoroDuration = duration
        self.pomodoroRemaining = duration
        lastPomodoroTick = nil
        defaults.set(duration, forKey: "pomodoroDuration")
    }

    private func tickPomodoro() {
        guard pomodoroActive, let lastTick = lastPomodoroTick else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        self.lastPomodoroTick = now

        if pomodoroRemaining > elapsed {
            pomodoroRemaining -= elapsed
        } else {
            pomodoroRemaining = 0
            pomodoroActive = false
            pomodoroTimer?.invalidate()
            pomodoroTimer = nil
            self.lastPomodoroTick = nil

            playPersistentAlarmHaptics()
        }
    }

    private func playPersistentAlarmHaptics() {
        // A self-terminating ~3s repeating haptic. Modeled as a cancellable
        // MainActor Task loop (not `Timer.scheduledTimer`) so the non-Sendable
        // `Timer` never has to cross an isolation boundary under Swift 6, and so
        // `stopPomodoro()` can silence a ringing alarm by cancelling the task.
        alarmHapticsTask?.cancel()
        alarmHapticsTask = Task { @MainActor [weak self] in
            let startTime = Date()
            WKInterfaceDevice.current().play(.notification)
            while !Task.isCancelled, Date().timeIntervalSince(startTime) < 3.0 {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                WKInterfaceDevice.current().play(.notification)
            }
            self?.alarmHapticsTask = nil
        }
    }

    func appWillEnterForeground() {
        updatePlaybackTimer()
        guard pomodoroActive else { return }

        if let lastTick = lastPomodoroTick {
            let elapsed = Date().timeIntervalSince(lastTick)
            self.lastPomodoroTick = Date()

            if pomodoroRemaining > elapsed {
                pomodoroRemaining -= elapsed

                if pomodoroTimer == nil {
                    pomodoroTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                        [weak self] _ in
                        guard let self else { return }
                        MainActor.assumeIsolated {
                            self.tickPomodoro()
                        }
                    }
                    // Recreated after returning to the foreground, so it needs the same
                    // common-mode registration as startPomodoro() or it re-freezes.
                    if let pomodoroTimer {
                        RunLoop.main.add(pomodoroTimer, forMode: .common)
                    }
                }
            } else {
                pomodoroRemaining = 0
                pomodoroActive = false
                pomodoroTimer?.invalidate()
                pomodoroTimer = nil
                lastPomodoroTick = nil

                playPersistentAlarmHaptics()
            }
        } else {
            lastPomodoroTick = Date()
        }
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

extension Color {
    init?(hex: String) {
        guard let rgb = HexRGB(hex: hex) else { return nil }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
