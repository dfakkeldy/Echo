// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudioEnginePauseTests {
    @Test func pausingBookPlaybackStopsTheSharedAudioEngine() async throws {
        let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 3)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let audioEngine = AudioEngine()
        audioEngine.configureAudioSession()
        audioEngine.replaceCurrentItem(with: audioURL)
        defer { audioEngine.cleanup() }

        audioEngine.playImmediately(atRate: 1)
        #expect(audioEngine.isEngineRunning)

        audioEngine.pause()

        #expect(audioEngine.isEngineRunning == false)

        audioEngine.play()

        #expect(audioEngine.isEngineRunning)
    }

    @Test func pausingBookPlaybackKeepsActiveSoundscapeRendering() async throws {
        let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 3)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let audioEngine = AudioEngine()
        audioEngine.configureAudioSession()
        audioEngine.replaceCurrentItem(with: audioURL)
        defer { audioEngine.cleanup() }

        audioEngine.playImmediately(atRate: 1)
        audioEngine.soundscapeMixer = ActiveSoundscapeStub()

        audioEngine.pause()

        #expect(audioEngine.isPlaying == false)
        #expect(audioEngine.isEngineRunning)
    }
}

@MainActor
private final class ActiveSoundscapeStub: SoundscapePlaying {
    let isActive = true
    var volume: Float = 0.5

    func play(preset: SoundscapePreset) async {}
    func stop() {}
}
