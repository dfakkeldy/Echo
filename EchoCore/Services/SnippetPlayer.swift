@preconcurrency import AVFoundation
import os.log

/// Plays a segment of an audio file using a separate AVAudioEngine instance,
/// following the same pattern as BookmarkStore voice memo playback.
///
/// Also serves as the unified preview player (replaces the former
/// AudioSnippetPlayer) with volume control and full-file playback support.
@MainActor
final class SnippetPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var didFinishPlayback = false
    private var currentGeneration: Int = 0

    private(set) var isPlaying: Bool = false
    var onPlaybackWillStart: (() -> Void)?
    var onPlaybackDidEnd: (() -> Void)?

    /// Plays a time-range segment of an audio file.
    func play(url: URL, startTime: TimeInterval, endTime: TimeInterval, volume: Float = 1.0) {
        stop()
        currentGeneration += 1
        let generation = currentGeneration

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            Logger(category: "SnippetPlayer").error("Failed to read audio file at \(url.path): \(error.localizedDescription)")
            onPlaybackDidEnd?()
            return
        }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, startTime * sampleRate))
        let endFrame = AVAudioFramePosition(min(Double(file.length), endTime * sampleRate))
        let framesToPlay = AVAudioFrameCount(endFrame - startFrame)
        guard framesToPlay > 0 else {
            Logger(category: "SnippetPlayer").error("Zero-length segment (start=\(startTime), end=\(endTime))")
            onPlaybackDidEnd?()
            return
        }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: file.processingFormat)
        eng.mainMixerNode.outputVolume = volume

        do {
            try eng.start()
        } catch {
            Logger(category: "SnippetPlayer").error("Engine start failed: \(error.localizedDescription)")
            onPlaybackDidEnd?()
            return
        }

        onPlaybackWillStart?()

        node.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) {
            Task { @MainActor [weak self] in
                guard let self, generation == self.currentGeneration else { return }
                self.handlePlaybackEnded()
            }
        }
        node.play()

        didFinishPlayback = false
        engine = eng
        playerNode = node
        isPlaying = true
    }

    /// Convenience: plays an entire audio file from start to finish.
    /// - Parameters:
    ///   - url: The audio file URL.
    ///   - volume: Output volume (0…1). Defaults to 1.0.
    ///   - completion: Called on the main actor when playback finishes.
    func play(url: URL, volume: Float = 1.0, completion: (() -> Void)? = nil) {
        guard let file = try? AVAudioFile(forReading: url) else {
            Logger(category: "SnippetPlayer").error("Failed to read file at \(url.path)")
            completion?()
            return
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let previousDidEnd = onPlaybackDidEnd
        onPlaybackDidEnd = { [weak self] in
            previousDidEnd?()
            completion?()
        }
        play(url: url, startTime: 0, endTime: duration, volume: volume)
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine?.reset()
        playerNode = nil
        engine = nil
        isPlaying = false
    }

    private func handlePlaybackEnded() {
        guard !didFinishPlayback else { return }
        didFinishPlayback = true
        stop()
        onPlaybackDidEnd?()
    }
}
