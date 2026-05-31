import AVFoundation
import os.log

/// A lightweight, single-use audio player for short snippets (voice-memo
/// previews, bookmark playback).  Eliminates the ad-hoc AVAudioEngine
/// setup duplicated across BookmarkStore, Bookmarks, and SnippetPlayer.
///
/// For full playback use `AudioEngine`; this utility is intended for
/// previews and snippets only.
final class AudioSnippetPlayer {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "AudioSnippetPlayer")
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var onComplete: (() -> Void)?

    /// Plays an entire audio file from start to finish.
    /// - Parameters:
    ///   - url: The audio file URL.
    ///   - volume: Output volume (0…1). Defaults to 1.0.
    ///   - completion: Called on the main actor when playback finishes.
    func play(url: URL, volume: Float = 1.0, completion: (() -> Void)? = nil) {
        stop()

        guard let file = try? AVAudioFile(forReading: url) else {
            logger.error("AudioSnippetPlayer: failed to read file at \(url.path)")
            completion?()
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
            logger.error("AudioSnippetPlayer: engine start failed: \(error.localizedDescription)")
            completion?()
            return
        }

        onComplete = completion
        node.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            // scheduleFile completion arrives on the render thread;
            // hop back to the main actor for state cleanup and callbacks.
            Task { @MainActor [weak self] in
                self?.handleComplete()
                self?.onComplete?()
            }
        }
        node.play()

        engine = eng
        playerNode = node
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine?.reset()
        playerNode = nil
        engine = nil
    }

    private func handleComplete() {
        stop()
    }
}
