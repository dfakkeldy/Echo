import AVFoundation
import Observation

// MARK: - AudioEngineDelegate

protocol AudioEngineDelegate: AnyObject {
    func audioEngineDidUpdateTime(_ engine: AudioEngine, currentTime: TimeInterval)
    func audioEngineDidPlayToEnd(_ engine: AudioEngine)
    func audioEngineInterruptionBegan(_ engine: AudioEngine)
    func audioEngineInterruptionEnded(_ engine: AudioEngine, shouldResume: Bool)
}

// MARK: - AudioEngine

/// Encapsulates AVAudioEngine-powered playback through an
/// AVAudioPlayerNode → AVAudioUnitEQ → AVAudioUnitVarispeed chain.
/// PlayerModel receives time/end/interruption events through the
/// delegate protocol. Chapter and bookmark boundary detection are
/// driven by the periodic time callback (0.25 s) rather than AVPlayer
/// boundary observers so that the engine migration keeps all of that
/// logic identical.
@Observable
final class AudioEngine {
    // MARK: - Observable State

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var speed: Float = 1.25
    private(set) var isVolumeBoostEnabled = false

    /// Whether an audio file is loaded and ready.
    var isItemLoaded: Bool { audioFile != nil && playerNode != nil }

    // MARK: - Delegate

    weak var delegate: AudioEngineDelegate?

    // MARK: - Engine & Nodes

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    private var varispeedNode: AVAudioUnitVarispeed?
    private var audioFile: AVAudioFile?

    // MARK: - Time Tracking

    /// The seek position at the start of the currently playing segment.
    /// `currentTime = seekOffset + Double(sampleTime) / sampleRate`
    private var seekOffset: TimeInterval = 0
    private var timeTimer: Timer?

    // MARK: - Interruption State

    private var interruptionObserver: NSObjectProtocol?
    private var mediaServicesLostObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var audioSessionConfigured = false

    deinit {
        cleanup()
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
            print("AudioSession error: \(error)")
        }
        setupInterruptionObserver()
        setupMediaServicesObservers()
        configureEngineGraph()
    }

    /// Build the node graph once; the engine is started on first `play()`.
    private func configureEngineGraph() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let eqNode = AVAudioUnitEQ()
        let varispeedNode = AVAudioUnitVarispeed()

        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(varispeedNode)

        engine.connect(playerNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: varispeedNode, format: nil)
        engine.connect(varispeedNode, to: engine.mainMixerNode, format: nil)

        engine.prepare()

        self.engine = engine
        self.playerNode = playerNode
        self.eqNode = eqNode
        self.varispeedNode = varispeedNode
    }

    // MARK: - Playback Controls

    func play() {
        guard let playerNode, engine != nil, isItemLoaded, !isPlaying else { return }
        startEngineIfNeeded()
        varispeedNode?.rate = speed
        playerNode.play()
        isPlaying = true
        startTimeTimer()
    }

    func playImmediately(atRate rate: Float) {
        setSpeed(rate)
        guard let playerNode, engine != nil, isItemLoaded else { return }
        startEngineIfNeeded()
        varispeedNode?.rate = rate
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

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        varispeedNode?.rate = newSpeed
    }

    // MARK: - Volume Boost

    /// Toggles a +9 dB global gain on the EQ node.
    func setVolumeBoost(enabled: Bool) {
        isVolumeBoostEnabled = enabled
        eqNode?.globalGain = enabled ? 9.0 : 0.0
    }

    // MARK: - Item Management

    /// Loads an audio file and schedules it from the given startTime.
    /// Maintains the play/pause state across item replacement.
    func replaceCurrentItem(with url: URL, startTime: TimeInterval? = nil) {
        let wasPlaying = isPlaying
        isPlaying = false
        stopTimeTimer()
        playerNode?.stop()

        let initialOffset = startTime ?? 0
        seekOffset = initialOffset
        currentTime = initialOffset
        duration = nil

        guard let playerNode, engine != nil else { return }

        do {
            let file = try AVAudioFile(forReading: url)
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
                varispeedNode?.rate = speed
                playerNode.play()
                isPlaying = true
                startTimeTimer()
            }
        } catch {
            print("AudioEngine: replaceCurrentItem error: \(error)")
            audioFile = nil
            duration = nil
        }
    }

    /// Stops playback and tears down the engine.
    func stop() {
        isPlaying = false
        playerNode?.pause()
        playerNode?.stop()
        engine?.stop()
        currentTime = 0
        duration = nil
        seekOffset = 0

        stopTimeTimer()
        removeInterruptionObserver()
        removeMediaServicesObservers()
        audioFile = nil
        audioSessionConfigured = false
    }

    func cleanup() {
        stop()
        engine = nil
        playerNode = nil
        eqNode = nil
        varispeedNode = nil
    }

    // MARK: - Private Helpers

    private func startEngineIfNeeded() {
        guard let engine, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("AudioEngine: engine start error: \(error)")
        }
    }

    private func scheduleSegment(file: AVAudioFile,
                                  from startFrame: AVAudioFramePosition,
                                  frames: AVAudioFrameCount) {
        playerNode?.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frames,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
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
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateCurrentTime()
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
                self.audioSessionConfigured = false
                self.isPlaying = false
                self.stopTimeTimer()
                self.delegate?.audioEngineInterruptionBegan(self)
            case .ended:
                let optionsValue = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                self.delegate?.audioEngineInterruptionEnded(self, shouldResume: options.contains(.shouldResume))
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

    private func setupMediaServicesObservers() {
        guard mediaServicesLostObserver == nil else { return }

        mediaServicesLostObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.stopTimeTimer()
            self.delegate?.audioEngineInterruptionBegan(self)
        }

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.audioSessionConfigured = false
            self.configureAudioSession()
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
