// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

@MainActor
final class StudyCheckpointAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private var chimePlayer: AVAudioPlayer?

    func announce(_ line: String) {
        playChime()
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func playChime() {
        guard let url = chimeURL() else { return }
        chimePlayer = try? AVAudioPlayer(contentsOf: url)
        chimePlayer?.volume = 0.4
        chimePlayer?.play()
    }

    private func chimeURL() -> URL? {
        for ext in ["caf", "wav", "aiff", "aif", "mp3", "m4a"] {
            if let url = Bundle.main.url(
                forResource: ChimeSound.softChime.rawValue,
                withExtension: ext
            ) {
                return url
            }
        }
        return nil
    }
}
