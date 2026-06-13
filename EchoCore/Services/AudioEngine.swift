@preconcurrency import AVFoundation
import Observation
import os.log

// MARK: - AudioEngineDelegate

protocol AudioEngineDelegate: AnyObject {
    func audioEngineDidUpdateTime(_ engine: AudioEngine, currentTime: TimeInterval)
    func audioEngineDidPlayToEnd(_ engine: AudioEngine)
    func audioEngineInterruptionBegan(_ engine: AudioEngine)
    func audioEngineInterruptionEnded(_ engine: AudioEngine, shouldResume: Bool)
    func audioEngineOutputDeviceDisconnected(_ engine: AudioEngine)
}

// MARK: - WS-4 Audio Engine Upgrade Protocols

protocol SoundscapePlaying: AnyObject {
    func play(preset: SoundscapePreset) async
    func stop()
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

    /// The URL of the currently loaded audio file, if any.
    var audioFileURL: URL? { audioFile?.url }

    // MARK: - Delegate

    weak var delegate: AudioEngineDelegate?

    // MARK: - Engine & Nodes

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    private var timePitchNode: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?

    // MARK: - WS-4 Subsystems

    nonisolated(unsafe) var soundscapeMixer: SoundscapePlaying?
    nonisolated(unsafe) var chimePlayer: ChimeScheduling?
    nonisolated(unsafe) var visualizerTap: VisualizerDataProviding?

    // MARK: - Time Tracking

    private var fadeTimer: Timer?

    /// The seek position at the start of the currently playing segment.
    /// `currentTime = seekOffset + Double(sampleTime) / sampleRate`
    private var seekOffset: TimeInterval = 0
    private var timeTimer: Timer?

    // MARK: - Interruption State

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesLostObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var audioSessionConfigured = false
    private var seekGeneration = 0

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }

    // MARK: - Audio Session

    func configureAudioSession() {
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            os_log(.error, "AudioSession error: %{private}@", error.localizedDescription)
        }
        setupInterruptionObserver()
        setupRouteChangeObserver()
        setupMediaServicesObservers()
        configureEngineGraph()
    }

    /// Build the node graph once; the engine is started on first `play()`.
    private func configureEngineGraph() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let eqNode = AVAudioUnitEQ()
        let timePitchNode = AVAudioUnitTimePitch()
        // A tiny non-zero pitch prevents the audio unit's internal passthrough
        // optimisation when rate=1.0, which would otherwise ignore rate changes
        // back to unity (e.g. 3x → 1x stuck at 3x). 0.01 cents is ~100x below
        // the ~5-cent just-noticeable pitch difference.
        timePitchNode.pitch = 0.01

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

        // Wire WS-4 subsystems into the audio graph.
        soundscapeMixer = DefaultSoundscapeMixer(engine: engine)
        chimePlayer = DefaultChimePlayer(engine: engine)
        visualizerTap = DefaultVisualizerTap(engine: engine)
    }

    // MARK: - Playback Controls

    func play() {
        guard let playerNode, engine != nil, isItemLoaded, !isPlaying else { return }
        startEngineIfNeeded()
        timePitchNode?.rate = speed
        playerNode.play()
        isPlaying = true
        startTimeTimer()
    }

    func playImmediately(atRate rate: Float) {
        setSpeed(rate)
        guard let playerNode, engine != nil, isItemLoaded else { return }
        startEngineIfNeeded()
        timePitchNode?.rate = rate
        playerNode.play()
        isPlaying = true
        startTimeTimer()
    }

    func pause() {
        playerNode?.pause()
        isPlaying = false
        stopTimeTimer()
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
            startEngineIfNeeded()
            playerNode.play()
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
            startEngineIfNeeded()
            playerNode.play()
            isPlaying = true
            startTimeTimer()
        }
        return true
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        timePitchNode?.rate = newSpeed
    }

    // MARK: - Gain Control

    /// Set the output gain of the EQ node. 0.0 = unity gain.
    /// Range typically -96 to 24 dB.
    func setGain(_ gain: Float) {
        eqNode?.globalGain = gain
    }

    /// Smoothly fade gain to a target value over the specified duration.
    /// Uses a repeating Timer at ~20 steps per second. Cancels any in-progress fade.
    func fadeGain(to targetGain: Float, duration: TimeInterval) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let eqNode else { return }
        let startGain = eqNode.globalGain
        let steps = Int(duration / 0.05)
        guard steps > 0 else {
            eqNode.globalGain = targetGain
            return
        }
        let gainDelta = (targetGain - startGain) / Float(steps)
        var currentStep = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in
                currentStep += 1
                if currentStep >= steps {
                    self.eqNode?.globalGain = targetGain
                    timer.invalidate()
                } else {
                    self.eqNode?.globalGain = startGain + gainDelta * Float(currentStep)
                }
            }
        }
        fadeTimer = timer
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
    func replaceCurrentItem(with url: URL, startTime: TimeInterval? = nil) {
        let wasPlaying = isPlaying
        isPlaying = false
        stopTimeTimer()
        seekGeneration += 1
        playerNode?.stop()

        let initialOffset = startTime ?? 0
        seekOffset = initialOffset
        currentTime = initialOffset
        duration = nil

        guard let playerNode, engine != nil else { return }

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

            guard framesToPlay > 0 else { return }

            seekOffset = clampedOffset
            currentTime = clampedOffset

            scheduleSegment(file: file, from: startFrame, frames: framesToPlay)

            if wasPlaying {
                startEngineIfNeeded()
                timePitchNode?.rate = speed
                playerNode.play()
                isPlaying = true
                startTimeTimer()
            }
        } catch {
            os_log(.error, "AudioEngine: replaceCurrentItem error: %{private}@", error.localizedDescription)
            audioFile = nil
            duration = nil
        }
    }

    /// Stops playback and tears down the engine.
    func stop() {
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

        fadeTimer?.invalidate()
        fadeTimer = nil
        stopTimeTimer()
        removeInterruptionObserver()
        removeRouteChangeObserver()
        removeMediaServicesObservers()
        audioFile = nil
        audioSessionConfigured = false
    }

    func cleanup() {
        stop()
        engine = nil
        playerNode = nil
        eqNode = nil
        timePitchNode = nil
        soundscapeMixer = nil
        chimePlayer = nil
        visualizerTap = nil
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

    private func startEngineIfNeeded() {
        guard let engine, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            os_log(.error, "AudioEngine: engine start error: %{private}@", error.localizedDescription)
        }
    }

    private func scheduleSegment(file: AVAudioFile,
                                  from startFrame: AVAudioFramePosition,
                                  frames: AVAudioFrameCount) {
        let generation = seekGeneration
        playerNode?.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frames,
            at: nil
        ) {
            Task { @MainActor [weak self] in
                guard let self, generation == self.seekGeneration else { return }
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

    private func updateCurrentTime() {
        guard let playerNode, isPlaying else { return }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }

        let position = Double(playerTime.sampleTime) / playerTime.sampleRate
        let time = seekOffset + position
        guard time.isFinite else { return }

        currentTime = time
        delegate?.audioEngineDidUpdateTime(self, currentTime: time)
    }

    // MARK: - Interruption Observers

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
                    self.audioSessionConfigured = false
                    self.isPlaying = false
                    self.stopTimeTimer()
                    self.delegate?.audioEngineInterruptionBegan(self)
                }
            case .ended:
                let optionsValue = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                let shouldResume = options.contains(.shouldResume)
                MainActor.assumeIsolated {
                    self.delegate?.audioEngineInterruptionEnded(self, shouldResume: shouldResume)
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
                self.isPlaying = false
                self.stopTimeTimer()
                self.delegate?.audioEngineInterruptionBegan(self)
            }
        }

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.audioSessionConfigured = false
                self.configureAudioSession()
            }
        }
    }

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
