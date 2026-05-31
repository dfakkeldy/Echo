import AVFoundation
import os.log

/// Plays a segment of an audio file using a separate AVAudioEngine instance,
/// following the same pattern as BookmarkStore voice memo playback.
@MainActor
final class SnippetPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var didFinishPlayback = false
    private var currentGeneration: Int = 0

    private(set) var isPlaying: Bool = false
    var onPlaybackWillStart: (() -> Void)?
    var onPlaybackDidEnd: (() -> Void)?

    func play(url: URL, startTime: TimeInterval, endTime: TimeInterval) {
        stop()
        currentGeneration += 1
        let generation = currentGeneration

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            os_log(.error, "SnippetPlayer: failed to read audio file at %{public}@: %{public}@", url.path, error.localizedDescription)
            onPlaybackDidEnd?()
            return
        }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, startTime * sampleRate))
        let endFrame = AVAudioFramePosition(min(Double(file.length), endTime * sampleRate))
        let framesToPlay = AVAudioFrameCount(endFrame - startFrame)
        guard framesToPlay > 0 else {
            os_log(.error, "SnippetPlayer: zero-length segment (start=%.2f, end=%.2f)", startTime, endTime)
            onPlaybackDidEnd?()
            return
        }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: file.processingFormat)

        do {
            try eng.start()
        } catch {
            os_log(.error, "SnippetPlayer: engine start failed: %{public}@", error.localizedDescription)
            onPlaybackDidEnd?()
            return
        }

        onPlaybackWillStart?()

        node.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
            Task { @MainActor in
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
