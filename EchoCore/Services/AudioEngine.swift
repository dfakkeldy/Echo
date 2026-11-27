// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import AVFoundation
import Observation
import os.log

nonisolated struct AudioItemLoadFailure: Error, Equatable, Sendable {
    let privateDetail: String
}

// MARK: - AudioEngineDelegate

protocol AudioEngineDelegate: AnyObject {
    func audioEngineDidUpdateTime(_ engine: AudioEngine, currentTime: TimeInterval)
    func audioEngineDidPlayToEnd(_ engine: AudioEngine)
    func audioEngineInterruptionBegan(_ engine: AudioEngine)
    func audioEngineInterruptionEnded(_ engine: AudioEngine, shouldResume: Bool)
    func audioEngineOutputDeviceDisconnected(_ engine: AudioEngine)
    /// The engine stopped itself on a hardware reconfiguration and could not be
    /// restarted at the current position. Settle into a real paused state.
    func audioEngineDidStopUnexpectedly(_ engine: AudioEngine)
}

// MARK: - WS-4 Audio Engine Upgrade Protocols

protocol SoundscapePlaying: AnyObject {
    func play(preset: SoundscapePreset) async
    func stop()
    var isActive: Bool { get }
    var volume: Float { get set }
}

protocol ChimeScheduling: AnyObject {
    func schedule(interval: TimeInterval, sound: ChimeSound)
    func cancel()
}

protocol VisualizerDataProviding: AnyObject {
    var frames: AsyncStream<VisualizerFrame> { get }
}

// MARK: - AudioEngine

/// Encapsulates AVAudioEngine-powered playback through an
/// AVAudioPlayerNode → AVAudioUnitEQ → AVAudioUnitTimePitch chain.
/// PlayerModel receives time/end/interruption events through the
/// delegate protocol. Chapter and bookmark boundary detection are
/// driven by the periodic time callback (0.25 s) rather than AVPlayer
/// boundary observers so that the engine migration keeps all of that
/// logic identical.
@MainActor @Observable
final class AudioEngine {
    // MARK: - Observable State

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var speed: Float = 1.25
    private(set) var isVolumeBoostEnabled = false

    /// Whether an audio file is loaded and ready.
    var isItemLoaded: Bool { audioFile != nil && playerNode != nil }

    /// Whether the shared render engine is currently active. Playback controls
    /// use this independently from `isPlaying` because ambient audio can keep
    /// rendering while the audiobook player node is paused.
    var isEngineRunning: Bool { engine?.isRunning == true }

    /// Whether the engine is listening for hardware reconfigurations. The
    /// original headphone-connect bug was that nothing observed this at all, so
    /// tests assert the observer is armed for as long as the graph exists.
    var isObservingConfigurationChanges: Bool { configurationChangeObserver != nil }

    /// The URL of the currently loaded audio file, if any.
    var audioFileURL: URL? { audioFile?.url }

    /// Identity of the current underlying AVAudioEngine instance, exposed for
    /// recovery tests verifying that an orphaned or wedged graph is replaced.
    var currentEngineIdentity: ObjectIdentifier? { engine.map(ObjectIdentifier.init) }

    /// Current gain applied to `eqNode`, exposed for recovery tests verifying
    /// volume boost / watch gain survives an engine graph rebuild.
    var currentEQGain: Float? { eqNode?.globalGain }

    /// Optional test seams for simulating audio-session and engine-start failures.
    @ObservationIgnored var engineStartHandler: ((AVAudioEngine) throws -> Void)?
    @ObservationIgnored var audioSessionActivator: (() throws -> Void)?

    // MARK: - Delegate

    weak var delegate: AudioEngineDelegate?

    // MARK: - Engine & Nodes

    private let ownsEngineGraph: Bool
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    private var timePitchNode: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?
    private var currentGain: Float = 0.0

    // MARK: - WS-4 Subsystems

    // Assigned at engine configuration and accessed only on the main actor
    // (teardown here, plus the settings/visualizer views), so these need no
    // isolation annotation — the prior `nonisolated(unsafe)` had no effect and
    // would have suppressed the observation the views rely on (audit §3.4).
    var soundscapeMixer: SoundscapePlaying?
    var chimePlayer: ChimeScheduling?
    var visualizerTap: VisualizerDataProviding?

    // MARK: - Time Tracking

    // A structured `Task` rather than a `Timer`: under Swift 6 a `Timer`'s
    // `@Sendable` callback cannot capture/mutate the fade's step counter or hop to
    // the main actor without tripping sending diagnostics. An `await Task.sleep`
    // loop keeps every fade step on the main actor with no isolation crossing.
    private var fadeTask: Task<Void, Never>?

    /// The seek position at the start of the currently playing segment.
    /// `currentTime = seekOffset + Double(sampleTime) / sampleRate`
    private var seekOffset: TimeInterval = 0
    private var timeTimer: Timer?

    // MARK: - Interruption State

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesLostObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var configurationChangeObserver: NSObjectProtocol?
    private var audioSessionConfigured = false
    private var seekGeneration = 0

    init() {
        self.ownsEngineGraph = true
    }

    /// Accept an already connected graph, including one configured for offline rendering.
    init(engine: AVAudioEngine, playerNode: AVAudioPlayerNode) {
        precondition(playerNode.engine === engine, "Player node must belong to the supplied engine")
        self.ownsEngineGraph = false
        self.engine = engine
        self.playerNode = playerNode
        setupConfigurationChangeObserver(for: engine)
    }

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }

    // MARK: - Audio Session

    @discardableResult
    private func activateAudioSession() -> Bool {
        if let audioSessionActivator {
            do {
                try audioSessionActivator()
                audioSessionConfigured = true
                return true
            } catch {
                let nsError = error as NSError
                os_log(
                    .error, "AudioSession error (%{public}@ %d): %{private}@",
                    nsError.domain, nsError.code, error.localizedDescription)
                audioSessionConfigured = false
                return false
            }
        }
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
                try session.setActive(true)
                audioSessionConfigured = true
                return true
            } catch {
                let nsError = error as NSError
                os_log(
                    .error, "AudioSession error (%{public}@ %d): %{private}@",
                    nsError.domain, nsError.code, error.localizedDescription)
                audioSessionConfigured = false
                return false
            }
        #else
            audioSessionConfigured = true
            return true
        #endif
    }

    func configureAudioSession() {
        guard !audioSessionConfigured else { return }
        _ = activateAudioSession()
        #if os(iOS)
            setupInterruptionObserver()
            setupRouteChangeObserver()
            setupMediaServicesObservers()
        #endif
        configureEngineGraph()
    }

    /// Build the node graph once; the engine is started on first `play()`.
    private func configureEngineGraph() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let eqNode = AVAudioUnitEQ()
        eqNode.globalGain = currentGain
        let timePitchNode = AVAudioUnitTimePitch()
        // A tiny non-zero pitch prevents the audio unit's internal passthrough
        // optimisation when rate=1.0, which would otherwise ignore rate changes
        // back to unity (e.g. 3x → 1x stuck at 3x). 0.01 cents is ~100x below
        // the ~5-cent just-noticeable pitch difference.
        timePitchNode.pitch = 0.01
        // Max out the phase-vocoder overlap (default 8.0, range 3–32). At high
        // playback rates (2x+) the default smears transients into audible
        // reverb/ringing — most noticeable on Kokoro narration, whose vocoder
        // already has a hot high end. 32 minimises that smearing; the extra CPU
        // is negligible for a single mono stream.
        timePitchNode.overlap = 32.0

        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(timePitchNode)

        engine.connect(playerNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: timePitchNode, format: nil)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)

        engine.prepare()

        self.engine = engine
        self.playerNode = playerNode
        self.eqNode = eqNode
        self.timePitchNode = timePitchNode
        applyPlaybackRate(speed)

        // Wire WS-4 subsystems into the audio graph.
        soundscapeMixer = DefaultSoundscapeMixer(engine: engine)
        chimePlayer = DefaultChimePlayer(engine: engine)
        visualizerTap = DefaultVisualizerTap(engine: engine)

        setupConfigurationChangeObserver(for: engine)
    }

    /// AVAudioEngine stops *itself* whenever the audio hardware configuration
    /// changes — most often when an output device **connects** (Bluetooth
    /// headphones waking up mid-book) or the default output device changes.
    /// Unlike an interruption or a disconnect, nothing else tells the app, so
    /// `isPlaying` is left true over a stopped engine: the transport keeps
    /// showing a pause button while silence plays, and the next tap pauses an
    /// already-stopped engine — which is why resuming took two presses.
    ///
    /// Scoped to this engine instance; `SnippetPlayer` and `BookmarkStore` build
    /// their own AVAudioEngines whose reconfigurations are none of our business.
    private func setupConfigurationChangeObserver(for engine: AVAudioEngine) {
        guard configurationChangeObserver == nil else { return }
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleConfigurationChange()
            }
        }
    }

    private func removeConfigurationChangeObserver() {
        if let obs = configurationChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        configurationChangeObserver = nil
    }

    /// Restart at the current position so playback follows the new route.
    ///
    /// The re-seek is load-bearing: a bare `engine.start()` would resume, but
    /// stopping resets the player node's sample time, and `currentTime` is
    /// derived from it (`seekOffset + sampleTime / sampleRate`), so resuming
    /// without rescheduling would rewind the book to the last seek point.
    /// Re-seeking rebases `seekOffset` onto the position we actually reached.
    func handleConfigurationChange() {
        // A reconfiguration while paused needs nothing: the next `play()` goes
        // through `startEngineIfNeeded()`, which restarts a stopped engine.
        // `!engine.isRunning` also stops the restart below from re-entering if
        // starting the engine posts a further configuration change.
        guard isPlaying, let engine, !engine.isRunning else { return }

        // A device leaving can reconfigure the engine too, and that notification
        // races `.oldDeviceUnavailable`. Resuming when we have landed back on the
        // built-in output would play the book out loud for the instant before the
        // disconnect handler's pause arrives — the very thing that handler exists
        // to prevent — so treat it as a stop rather than a route to follow.
        guard !reconfiguredOntoBuiltInOutput else {
            reportUnexpectedStop()
            return
        }

        seek(to: currentTime) { [weak self] rescheduled in
            guard let self else { return }
            if rescheduled, self.engine?.isRunning == true { return }
            // The engine would not come back. Report a real pause rather than
            // leaving a pause button sitting over a dead engine.
            self.reportUnexpectedStop()
        }
    }

    /// True when the new route is the device's own speaker/receiver, i.e. the
    /// output device went away rather than arrived. Always false off iOS, where
    /// there is no AVAudioSession and a reconfiguration is a switch *to* a device.
    private var reconfiguredOntoBuiltInOutput: Bool {
        #if os(iOS)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            return !outputs.isEmpty
                && outputs.allSatisfy {
                    $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
                }
        #else
            return false
        #endif
    }

    /// Stop detection may arrive before the configuration notification. Preserve
    /// route recovery, including the built-in-output pause rule, in either order.
    func handleStoppedPlayback() {
        guard isPlaying else { return }
        if engine?.isRunning == false {
            handleConfigurationChange()
        } else {
            reportUnexpectedStop()
        }
    }

    /// Settle into a truthful paused transport after the engine stopped on us.
    private func reportUnexpectedStop() {
        isPlaying = false
        stopTimeTimer()
        delegate?.audioEngineDidStopUnexpectedly(self)
    }

    // MARK: - Playback Controls

    func play() {
        guard let playerNode, let engine, isItemLoaded else { return }
        guard !isPlaying || !engine.isRunning || !playerNode.isPlaying else { return }
        resumePlayback(atRate: speed)
    }

    func playImmediately(atRate rate: Float) {
        setSpeed(rate)
        guard let playerNode, let engine, isItemLoaded else { return }
        // A speed update while playing must not rebase or replace the active segment.
        if isPlaying && engine.isRunning && playerNode.isPlaying {
            applyPlaybackRate(rate)
            return
        }
        resumePlayback(atRate: rate)
    }

    private func resumePlayback(atRate rate: Float) {
        // stop() removed the route/interruption observers and cleared the
        // session-configured flag; re-arm before resuming so unplugging
        // headphones or an interruption still pauses playback (§5.9).
        if !audioSessionConfigured {
            configureAudioSession()
        } else if ownsEngineGraph || audioSessionActivator != nil {
            // Re-activate the audio session on resume from pause/stop: iOS,
            // CarPlay/Bluetooth route transitions, Siri, or VoiceMemoRecorder
            // can deactivate it while paused without firing .began.
            _ = activateAudioSession()
        }
        guard rescheduleForResume() else { return }
        guard startEngineWithRecovery(at: currentTime) else {
            reportUnexpectedStop()
            return
        }
        applyPlaybackRate(rate)
        guard let activePlayerNode = self.playerNode else {
            reportUnexpectedStop()
            return
        }
        activePlayerNode.play()
        isPlaying = true
        startTimeTimer()
    }

    func pause() {
        updateCurrentTime(notifyDelegate: false)
        // A completion already queued for the main actor must not undo this pause.
        seekGeneration += 1
        playerNode?.pause()
        isPlaying = false
        stopTimeTimer()
        if soundscapeMixer?.isActive != true {
            engine?.pause()
        }
    }

    /// Rebuild even a loaded item's queue: node/engine resets can discard scheduled audio.
    private func rescheduleForResume() -> Bool {
        var rescheduled = false
        seek(to: currentTime) { rescheduled = $0 }
        return rescheduled
    }

    func seek(to targetSeconds: Double, completion: ((Bool) -> Void)? = nil) {
        guard let playerNode, let audioFile, engine != nil else {
            completion?(false)
            return
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        let clampedTime = max(0, min(targetSeconds, Double(totalFrames) / sampleRate))
        let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
        let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

        guard framesToPlay > 0 else {
            completion?(false)
            return
        }

        let wasPlaying = isPlaying
        isPlaying = false
        stopTimeTimer()
        seekGeneration += 1
        playerNode.stop()
        seekOffset = clampedTime
        currentTime = clampedTime

        scheduleSegment(file: audioFile, from: startFrame, frames: framesToPlay)

        if wasPlaying {
            guard startEngineWithRecovery(at: clampedTime) else {
                reportUnexpectedStop()
                completion?(false)
                return
            }
            applyPlaybackRate(speed)
            guard let activePlayerNode = self.playerNode else {
                reportUnexpectedStop()
                completion?(false)
                return
            }
            activePlayerNode.play()
            isPlaying = true
            startTimeTimer()
        }
        completion?(true)
    }

    /// Async overload of seek(to:) — returns true on success.
    /// Callers no longer need to wrap in DispatchQueue.main.async.
    func seek(to targetSeconds: Double) async -> Bool {
        guard let playerNode, let audioFile, engine != nil else { return false }

        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        let clampedTime = max(0, min(targetSeconds, Double(totalFrames) / sampleRate))
        let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
        let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

        guard framesToPlay > 0 else { return false }

        let wasPlaying = isPlaying
        isPlaying = false
        stopTimeTimer()
        seekGeneration += 1
        playerNode.stop()
        seekOffset = clampedTime
        currentTime = clampedTime

        scheduleSegment(file: audioFile, from: startFrame, frames: framesToPlay)

        if wasPlaying {
            guard startEngineWithRecovery(at: clampedTime) else {
                reportUnexpectedStop()
                return false
            }
            applyPlaybackRate(speed)
            guard let activePlayerNode = self.playerNode else {
                reportUnexpectedStop()
                return false
            }
            activePlayerNode.play()
            isPlaying = true
            startTimeTimer()
        }
        return true
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        applyPlaybackRate(newSpeed)
    }

    /// Apply a playback rate to the time-pitch unit. At unity (1.0×) the unit is
    /// **bypassed** — a clean passthrough — so the phase-vocoder never processes
    /// audio it isn't actually time-stretching. That unconditional 1× processing
    /// (kept engaged by the old `pitch = 0.01` workaround) added a metallic
    /// "whine"/reverb audible on-device versus the raw 1× file — the render itself
    /// is clean. Above/below unity the unit is engaged and the rate applied; the
    /// explicit bypass also cleanly handles the 3×→1× transition the workaround
    /// was guarding against (no "stuck at 3×").
    private func applyPlaybackRate(_ rate: Float) {
        guard let timePitchNode else { return }
        if abs(rate - 1.0) < 0.0001 {
            timePitchNode.auAudioUnit.shouldBypassEffect = true
        } else {
            timePitchNode.auAudioUnit.shouldBypassEffect = false
            timePitchNode.rate = rate
        }
    }

    // MARK: - Gain Control

    /// Set the output gain of the EQ node. 0.0 = unity gain.
    /// Range typically -96 to 24 dB.
    func setGain(_ gain: Float) {
        currentGain = gain
        eqNode?.globalGain = gain
    }

    /// Smoothly fade gain to a target value over the specified duration.
    /// Uses a repeating Timer at ~20 steps per second. Cancels any in-progress fade.
    func fadeGain(to targetGain: Float, duration: TimeInterval) {
        fadeTask?.cancel()
        fadeTask = nil
        guard let eqNode else {
            currentGain = targetGain
            return
        }
        let startGain = eqNode.globalGain
        let steps = Int(duration / 0.05)
        guard steps > 0 else {
            currentGain = targetGain
            eqNode.globalGain = targetGain
            return
        }
        let gainDelta = (targetGain - startGain) / Float(steps)
        // Ramp on the main actor (the class is @MainActor), one step every 50 ms.
        // `[weak self]` mirrors the old Timer's weak capture so an in-flight fade
        // never keeps the engine alive.
        fadeTask = Task { @MainActor [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                guard let self, let eqNode = self.eqNode else { return }
                if step >= steps {
                    self.currentGain = targetGain
                    eqNode.globalGain = targetGain
                    self.fadeTask = nil
                } else {
                    let nextGain = startGain + gainDelta * Float(step)
                    self.currentGain = nextGain
                    eqNode.globalGain = nextGain
                }
            }
        }
    }

    // MARK: - Volume Boost

    /// Toggles the volume boost on the EQ node using the configured gain (default +9 dB).
    func setVolumeBoost(enabled: Bool, gainDB: Float = 9.0) {
        isVolumeBoostEnabled = enabled
        setGain(enabled ? gainDB : 0.0)
    }

    // MARK: - Item Management

    /// Loads an audio file and schedules it from the given startTime.
    /// Maintains the play/pause state across item replacement.
    @discardableResult
    func replaceCurrentItem(
        with url: URL, startTime: TimeInterval? = nil
    ) -> Result<Void, AudioItemLoadFailure> {
        let wasPlaying = isPlaying
        isPlaying = false
        stopTimeTimer()
        seekGeneration += 1
        playerNode?.stop()

        let initialOffset = startTime ?? 0
        seekOffset = initialOffset
        currentTime = initialOffset
        duration = nil

        guard playerNode != nil, engine != nil else {
            return .failure(
                AudioItemLoadFailure(privateDetail: "Audio engine is not configured"))
        }

        do {
            // Use prebuffered file if it matches the target URL (saves disk I/O).
            let file: AVAudioFile
            if let pre = prebufferedFile, pre.url.absoluteString == url.absoluteString {
                file = pre
                prebufferedFile = nil
            } else {
                file = try AVAudioFile(forReading: url)
            }
            audioFile = file

            let sampleRate = file.processingFormat.sampleRate
            let fileDuration = Double(file.length) / sampleRate
            duration = fileDuration

            let clampedOffset = max(0, min(initialOffset, fileDuration))
            let startFrame = AVAudioFramePosition(clampedOffset * sampleRate)
            let framesToPlay = AVAudioFrameCount(file.length - startFrame)

            guard framesToPlay > 0 else {
                audioFile = nil
                duration = nil
                return .failure(
                    AudioItemLoadFailure(privateDetail: "Audio file contains no playable frames"))
            }

            seekOffset = clampedOffset
            currentTime = clampedOffset

            scheduleSegment(file: file, from: startFrame, frames: framesToPlay)

            if wasPlaying {
                guard startEngineWithRecovery(at: clampedOffset) else {
                    reportUnexpectedStop()
                    return .failure(AudioItemLoadFailure(privateDetail: "Audio engine could not start"))
                }
                applyPlaybackRate(speed)
                guard let activePlayerNode = self.playerNode else {
                    reportUnexpectedStop()
                    return .failure(AudioItemLoadFailure(privateDetail: "Audio engine could not start"))
                }
                activePlayerNode.play()
                isPlaying = true
                startTimeTimer()
            }
            return .success(())
        } catch {
            os_log(
                .error, "AudioEngine: replaceCurrentItem error: %{private}@",
                error.localizedDescription)
            audioFile = nil
            duration = nil
            return .failure(
                AudioItemLoadFailure(
                    privateDetail:
                        "\(String(reflecting: type(of: error))): \(error.localizedDescription)"))
        }
    }

    /// Stops playback and tears down the engine.
    func stop() {
        seekGeneration += 1
        prebufferedFile = nil
        isPlaying = false
        playerNode?.pause()
        playerNode?.stop()
        engine?.stop()
        currentTime = 0
        duration = nil
        seekOffset = 0

        // Stop WS-4 subsystems.
        soundscapeMixer?.stop()
        chimePlayer?.cancel()

        fadeTask?.cancel()
        fadeTask = nil
        stopTimeTimer()
        #if os(iOS)
            removeInterruptionObserver()
            removeRouteChangeObserver()
            removeMediaServicesObservers()
        #endif
        audioFile = nil
        audioSessionConfigured = false
    }

    func cleanup() {
        stop()
        // Paired with `configureEngineGraph()`, not with `stop()`: the engine
        // instance survives `stop()` and the graph builder early-returns while
        // it does, so tearing the observer down there would never re-arm it.
        tearDownEngineGraph()
    }

    private func tearDownEngineGraph() {
        removeConfigurationChangeObserver()
        soundscapeMixer?.stop()
        chimePlayer?.cancel()
        playerNode?.stop()
        engine?.stop()
        engine?.reset()
        engine = nil
        playerNode = nil
        eqNode = nil
        timePitchNode = nil
        soundscapeMixer = nil
        chimePlayer = nil
        visualizerTap = nil
    }

    /// Tears down the current `AVAudioEngine` graph and builds a fresh one,
    /// preserving gain, speed, and any loaded audio item scheduled at `resumeTime`.
    /// Required after `mediaServicesWereReset` (which permanently orphans existing
    /// audio objects) and as self-healing recovery when `engine.start()` fails
    /// after a hardware route/format reconfiguration while paused.
    @discardableResult
    private func rebuildEngineGraphPreservingLoadedItem(at resumeTime: TimeInterval? = nil) -> Bool {
        guard ownsEngineGraph else { return false }

        let savedFile = audioFile
        let savedURL = savedFile?.url
        let savedDuration = duration
        let targetTime = resumeTime ?? currentTime

        seekGeneration += 1
        isPlaying = false
        stopTimeTimer()
        prebufferedFile = nil

        tearDownEngineGraph()
        audioFile = nil

        audioSessionConfigured = false
        configureAudioSession()

        guard playerNode != nil, engine != nil else { return false }
        eqNode?.globalGain = currentGain
        applyPlaybackRate(speed)

        guard let savedFile else {
            duration = savedDuration
            seekOffset = targetTime
            currentTime = targetTime
            return true
        }

        let restoredFile: AVAudioFile
        if let savedURL, let reopened = try? AVAudioFile(forReading: savedURL) {
            restoredFile = reopened
        } else {
            restoredFile = savedFile
        }

        audioFile = restoredFile
        let sampleRate = restoredFile.processingFormat.sampleRate
        let totalFrames = restoredFile.length
        let fileDuration = sampleRate > 0 ? Double(totalFrames) / sampleRate : (savedDuration ?? 0)
        duration = fileDuration > 0 ? fileDuration : savedDuration

        let clampedTime = max(0, min(targetTime, fileDuration))
        let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
        let framesToPlay =
            totalFrames > startFrame ? AVAudioFrameCount(totalFrames - startFrame) : 0

        seekOffset = clampedTime
        currentTime = clampedTime

        guard framesToPlay > 0 else { return false }

        scheduleSegment(file: restoredFile, from: startFrame, frames: framesToPlay)
        return true
    }

    /// Rebuilds an orphaned `AVAudioEngine` graph after `mediaserverd` resets.
    /// Without replacing `engine`, `configureEngineGraph()` early-returns and
    /// every subsequent `play()` across all books fails until force-quit.
    func handleMediaServicesReset() {
        let wasPlaying = isPlaying
        audioSessionConfigured = false
        if ownsEngineGraph {
            _ = rebuildEngineGraphPreservingLoadedItem()
        } else {
            configureAudioSession()
        }
        if wasPlaying {
            reportUnexpectedStop()
        }
    }

    // MARK: - Pre-buffering (multi-M4B gapless transition)

    private var prebufferedFile: AVAudioFile?

    func prebuffer(next url: URL) {
        guard let engine, engine.isRunning else { return }
        do {
            prebufferedFile = try AVAudioFile(forReading: url)
        } catch {
            prebufferedFile = nil
        }
    }

    // MARK: - Private Helpers

    private func startEngineWithRecovery(at targetTime: TimeInterval) -> Bool {
        if startEngineIfNeeded() {
            return true
        }
        guard ownsEngineGraph else { return false }
        os_log(.error, "AudioEngine: rebuilding audio graph after engine start failure")
        guard rebuildEngineGraphPreservingLoadedItem(at: targetTime) else {
            return false
        }
        return startEngineIfNeeded()
    }

    private func startEngineIfNeeded() -> Bool {
        guard let engine else { return false }
        if engine.isRunning { return true }
        do {
            if let engineStartHandler {
                try engineStartHandler(engine)
            } else {
                try engine.start()
            }
            return engine.isRunning
        } catch {
            let nsError = error as NSError
            os_log(
                .error, "AudioEngine: engine start error (%{public}@ %d): %{private}@",
                nsError.domain, nsError.code, error.localizedDescription)
            return false
        }
    }

    private func scheduleSegment(
        file: AVAudioFile,
        from startFrame: AVAudioFramePosition,
        frames: AVAudioFrameCount
    ) {
        let generation = seekGeneration
        playerNode?.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frames,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.seekGeneration else { return }
                // Typed completion can also be delivered on stop. A cancelled/reset
                // graph is not EOF; retain the last genuine clock for rescheduling.
                guard self.isPlaying, self.engine?.isRunning == true,
                    self.playerNode?.isPlaying == true
                else {
                    if self.isPlaying { self.handleStoppedPlayback() }
                    return
                }
                self.isPlaying = false
                self.stopTimeTimer()
                self.currentTime = self.duration ?? self.currentTime
                self.delegate?.audioEngineDidPlayToEnd(self)
            }
        }
    }

    // MARK: - Time Timer

    private func startTimeTimer() {
        stopTimeTimer()
        // 2 Hz tick — frequent enough for smooth time-label updates and scrubber
        // tracking, while halving the view-tree re-evaluation cost vs. the old 4 Hz.
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateCurrentTime()
            }
        }
        if let timer = timeTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = nil
    }

    private func updateCurrentTime(notifyDelegate: Bool = true) {
        guard isPlaying, let playerNode else { return }
        guard engine?.isRunning == true, playerNode.isPlaying else {
            if notifyDelegate { handleStoppedPlayback() }
            return
        }
        guard let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return }

        let position = Double(playerTime.sampleTime) / playerTime.sampleRate
        let time = seekOffset + position
        // A node reset rewinds its sample clock. Only a seek/replacement may move
        // the book clock backwards; never overwrite the saved resume position here.
        guard time.isFinite else { return }
        guard time >= currentTime else {
            if notifyDelegate { handleStoppedPlayback() }
            return
        }

        currentTime = time
        if notifyDelegate { delegate?.audioEngineDidUpdateTime(self, currentTime: time) }
    }

    // MARK: - Interruption Observers

    #if os(iOS)
        func handleInterruptionBegan() {
            audioSessionConfigured = false
            pause()
            delegate?.audioEngineInterruptionBegan(self)
        }

        private func setupInterruptionObserver() {
            guard interruptionObserver == nil else { return }
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self,
                    let userInfo = notification.userInfo,
                    let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: typeValue)
                else { return }

                switch type {
                case .began:
                    MainActor.assumeIsolated {
                        self.handleInterruptionBegan()
                    }
                case .ended:
                    let optionsValue = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    let shouldResume = options.contains(.shouldResume)
                    MainActor.assumeIsolated {
                        self.delegate?.audioEngineInterruptionEnded(
                            self, shouldResume: shouldResume)
                    }
                @unknown default:
                    break
                }
            }
        }

        private func removeInterruptionObserver() {
            if let obs = interruptionObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            interruptionObserver = nil
        }

        private func setupRouteChangeObserver() {
            guard routeChangeObserver == nil else { return }
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self,
                    let userInfo = notification.userInfo,
                    let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                    let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
                else { return }

                // `.oldDeviceUnavailable` fires when the previous output device (wired
                // headphones, aux / line-out, or Bluetooth) is removed. AVAudioEngine,
                // unlike AVPlayer, does NOT auto-pause on this — left unhandled it falls
                // back to the built-in speaker and keeps rendering, so the book suddenly
                // plays out loud when you pull the cable. Pause to match expected behaviour.
                guard reason == .oldDeviceUnavailable else { return }
                MainActor.assumeIsolated {
                    guard self.isPlaying else { return }
                    self.delegate?.audioEngineOutputDeviceDisconnected(self)
                }
            }
        }

        private func removeRouteChangeObserver() {
            if let obs = routeChangeObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            routeChangeObserver = nil
        }

        private func setupMediaServicesObservers() {
            guard mediaServicesLostObserver == nil else { return }

            mediaServicesLostObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handleInterruptionBegan()
                }
            }

            mediaServicesResetObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handleMediaServicesReset()
                }
            }
        }

    #endif

    private func removeMediaServicesObservers() {
        if let obs = mediaServicesLostObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        mediaServicesLostObserver = nil
        if let obs = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        mediaServicesResetObserver = nil
    }
}
