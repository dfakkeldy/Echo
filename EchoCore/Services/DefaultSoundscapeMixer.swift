import AVFoundation
import os.log

// MARK: - DefaultSoundscapeMixer

/// Manages looping ambient audio playback on a dedicated player node
/// with an EQ ducking channel. Supports both file-based presets and
/// generative (noise / tone) presets via `AVAudioSourceNode`.
final class DefaultSoundscapeMixer: SoundscapePlaying {
    private weak var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    private var sourceNode: AVAudioSourceNode?
    private var isLooping = false
    private var currentFile: AVAudioFile?

    var volume: Float {
        get { playerNode?.volume ?? 0.5 }
        set { playerNode?.volume = newValue }
    }

    // MARK: - Init

    init(engine: AVAudioEngine) {
        self.engine = engine
        setupNodes()
    }

    private func setupNodes() {
        guard let engine else { return }
        let playerNode = AVAudioPlayerNode()
        let eqNode = AVAudioUnitEQ()

        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.connect(playerNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: engine.mainMixerNode, format: nil)

        playerNode.volume = 0.5

        self.playerNode = playerNode
        self.eqNode = eqNode
    }

    // MARK: - SoundscapePlaying

    func play(preset: SoundscapePreset) async {
        guard let engine, let playerNode else { return }
        stop()

        if let fileName = preset.fileName {
            await playFromFile(named: fileName, playerNode: playerNode)
        } else if let config = preset.generatorConfig {
            startGenerator(config: config)
            playerNode.play()
        }
    }

    func stop() {
        isLooping = false
        currentFile = nil
        playerNode?.stop()

        if let sourceNode, let engine {
            engine.detach(sourceNode)
        }
        sourceNode = nil
    }

    // MARK: - File Playback

    private func playFromFile(named fileName: String, playerNode: AVAudioPlayerNode) async {
        guard let soundURL = findFile(named: fileName) else {
            os_log(.error, "SoundscapeMixer: '%@' not found in bundle", fileName)
            return
        }

        do {
            let file = try AVAudioFile(forReading: soundURL)
            currentFile = file
            isLooping = true
            scheduleLoop(file: file)
            playerNode.play()
        } catch {
            os_log(.error, "SoundscapeMixer: file error %{private}@", error.localizedDescription)
        }
    }

    /// Searches Bundle.main for the file with a common audio extension.
    private func findFile(named fileName: String) -> URL? {
        let extensions = ["caf", "wav", "aiff", "aif", "mp3", "m4a", "aac"]
        for ext in extensions {
            if let url = Bundle.main.url(forResource: fileName, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private func scheduleLoop(file: AVAudioFile) {
        playerNode?.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self, self.isLooping, let file = self.currentFile else { return }
            Task { @MainActor in
                self.scheduleLoop(file: file)
            }
        }
    }

    // MARK: - Generative Audio

    private func startGenerator(config: SoundscapePreset.GeneratorConfig) {
        // Remove any previous source node.
        if let old = sourceNode, let engine {
            engine.detach(old)
        }

        let sampleRate: Double = 44100
        let amplitude: Float = volume * 0.3

        let node: AVAudioSourceNode
        switch config.type {
        case .whiteNoise:
            node = makeWhiteNoiseNode(amplitude: amplitude)
        case .pinkNoise:
            node = makePinkNoiseNode(sampleRate: sampleRate, amplitude: amplitude)
        case .brownNoise:
            node = makeBrownNoiseNode(sampleRate: sampleRate, amplitude: amplitude)
        case .binauralBeats, .isochronic:
            let carrier = config.carrierFrequency ?? 200
            let beat = config.beatFrequency ?? 10
            let pulse = config.pulseRate
            if config.type == .binauralBeats {
                node = makeBinauralBeatsNode(carrierHz: carrier, beatHz: beat, sampleRate: sampleRate, amplitude: amplitude)
            } else {
                node = makeIsochronicNode(frequency: carrier, pulseRate: pulse ?? 10, sampleRate: sampleRate, amplitude: amplitude)
            }
        }

        guard let engine else { return }
        engine.attach(node)
        engine.connect(node, to: eqNode ?? engine.mainMixerNode, format: nil)
        sourceNode = node
    }

    /// White noise: uniform random samples.
    private func makeWhiteNoiseNode(amplitude: Float) -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frameCount) {
                    ptr[frame] = (Float.random(in: -1...1)) * amplitude
                }
            }
            return noErr
        }
    }

    /// Pink noise: 3-stage averaging filter (Paul Kellet method).
    private func makePinkNoiseNode(sampleRate: Double, amplitude: Float) -> AVAudioSourceNode {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0
        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frameCount) {
                    let white = Float.random(in: -1...1)
                    // 3-stage averaging for -3dB/octave rolloff
                    b0 = 0.99886 * b0 + white * 0.0555179
                    b1 = 0.99332 * b1 + white * 0.0750759
                    b2 = 0.96900 * b2 + white * 0.1538520
                    b3 = 0.86650 * b3 + white * 0.3104856
                    b4 = 0.55000 * b4 + white * 0.5329522
                    b5 = -0.7616 * b5 - white * 0.0168980
                    let pink = (b0 + b1 + b2 + b3 + b4 + b5 + white * 0.5362) * 0.11
                    ptr[frame] = pink * amplitude
                }
            }
            return noErr
        }
    }

    /// Brown noise: integrated white noise (slightly leaky).
    private func makeBrownNoiseNode(sampleRate: Double, amplitude: Float) -> AVAudioSourceNode {
        var lastOut: Float = 0
        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frameCount) {
                    let white = Float.random(in: -1...1)
                    lastOut = (lastOut + (0.02 * white)) / 1.02
                    ptr[frame] = lastOut * amplitude * 3.0
                }
            }
            return noErr
        }
    }

    /// Binaural beats: two slightly-detuned sine waves for left/right separation.
    private func makeBinauralBeatsNode(carrierHz: Double, beatHz: Double, sampleRate: Double, amplitude: Float) -> AVAudioSourceNode {
        var phase: Double = 0
        let stepLeft = 2 * Double.pi * carrierHz / sampleRate
        let stepRight = 2 * Double.pi * (carrierHz + beatHz) / sampleRate

        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let binfo = audioBufferList.pointee.mBuffers
            let channelCount = Int(binfo.mNumberChannels > 0 ? binfo.mNumberChannels : 2)
            for buffer in ablPointer {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let isRight = (buffer.mData == ablPointer[1].mData) || (channelCount == 1 && ablPointer.count > 1 && buffer.mData == ablPointer[1].mData)
                let step = isRight ? stepRight : stepLeft
                for frame in 0..<Int(frameCount) {
                    let sample = sin(phase) * Double(amplitude)
                    ptr[frame] = Float(sample)
                    phase += step
                }
            }
            return noErr
        }
    }

    /// Isochronic tones: pulsed sine wave at the given frequency.
    private func makeIsochronicNode(frequency: Double, pulseRate: Double, sampleRate: Double, amplitude: Float) -> AVAudioSourceNode {
        var phase: Double = 0
        let step = 2 * Double.pi * frequency / sampleRate
        let pulseInterval = sampleRate / pulseRate
        var sampleCount: Double = 0

        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frameCount) {
                    // Amplitude modulation by pulse wave
                    let pulseMod: Float = sin(Double.pi * sampleCount / pulseInterval) > 0 ? amplitude : 0
                    let sample = sin(phase) * Double(pulseMod)
                    ptr[frame] = Float(sample)
                    phase += step
                    sampleCount += 1
                }
            }
            return noErr
        }
    }
}
