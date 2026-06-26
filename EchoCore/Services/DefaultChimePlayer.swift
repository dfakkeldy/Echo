// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import os.log

// MARK: - DefaultChimePlayer

/// Plays one-shot chime sounds on a configurable interval using a
/// dedicated `AVAudioPlayerNode`. The schedule runs as a `Task`
/// so it can be cancelled cleanly.
final class DefaultChimePlayer: ChimeScheduling {
    private weak var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var chimeTask: Task<Void, Never>?

    // MARK: - Init

    init(engine: AVAudioEngine) {
        self.engine = engine
        setupNodes()
    }

    private func setupNodes() {
        guard let engine else { return }
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        self.playerNode = playerNode
    }

    // MARK: - ChimeScheduling

    func schedule(interval: TimeInterval, sound: ChimeSound) {
        cancel()

        guard interval > 0 else { return }

        chimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.fireChime(sound: sound)
            }
        }
    }

    func cancel() {
        chimeTask?.cancel()
        chimeTask = nil
    }

    // MARK: - Private

    private func fireChime(sound: ChimeSound) async {
        guard let playerNode else { return }

        guard let chimeURL = findChimeFile(named: sound.rawValue) else {
            os_log(.error, "ChimePlayer: '%@' not found in bundle", sound.rawValue)
            return
        }

        do {
            let file = try AVAudioFile(forReading: chimeURL)
            // Pass an explicit completion handler to select the non-blocking
            // overload; the bare `scheduleFile(_:at:)` now resolves to the
            // `async` variant that suspends until playback finishes.
            playerNode.scheduleFile(file, at: nil, completionHandler: nil)
            startEngineIfNeeded()
            playerNode.play()
        } catch {
            os_log(.error, "ChimePlayer: error %{private}@", error.localizedDescription)
        }
    }

    private func findChimeFile(named fileName: String) -> URL? {
        let extensions = ["caf", "wav", "aiff", "aif", "mp3", "m4a"]
        for ext in extensions {
            if let url = Bundle.main.url(forResource: fileName, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private func startEngineIfNeeded() {
        guard let engine, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            os_log(
                .error, "ChimePlayer: engine start error: %{private}@", error.localizedDescription)
        }
    }

    // The class is inferred `@MainActor` under the project's MainActor default
    // isolation, so a plain nonisolated `deinit` cannot call the MainActor
    // `cancel()`. `isolated deinit` (SE-0371) runs the deinit on the actor,
    // letting it tear down the schedule task safely.
    isolated deinit {
        cancel()
    }
}
