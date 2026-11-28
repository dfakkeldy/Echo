// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import AVFoundation
    import Foundation
    import Testing

    @testable import Echo

    /// Regression guards for playback getting permanently stuck after a pause +
    /// route change / audio-session deactivation / media-services reset so no
    /// book can play until force-quit.
    @MainActor
    @Suite(.serialized)
    struct AudioEngineRecoveryTests {

        @Test func engineStartFailureRebuildsGraphAndResumesPlayback() async throws {
            let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 4)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let audioEngine = AudioEngine()
            defer { audioEngine.cleanup() }
            audioEngine.configureAudioSession()
            audioEngine.setVolumeBoost(enabled: true, gainDB: 7.5)
            try audioEngine.replaceCurrentItem(with: audioURL, startTime: 1.25).get()

            let originalEngineID = try #require(audioEngine.currentEngineIdentity)
            var attemptedEngines: [ObjectIdentifier] = []
            audioEngine.engineStartHandler = { engine in
                let id = ObjectIdentifier(engine)
                attemptedEngines.append(id)
                if id == originalEngineID {
                    throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                }
                try engine.start()
            }

            audioEngine.playImmediately(atRate: 1.25)

            let rebuiltEngineID = try #require(audioEngine.currentEngineIdentity)
            #expect(rebuiltEngineID != originalEngineID)
            #expect(attemptedEngines == [originalEngineID, rebuiltEngineID])
            #expect(audioEngine.isPlaying)
            #expect(audioEngine.isEngineRunning)
            #expect(audioEngine.isObservingConfigurationChanges)
            #expect(abs(audioEngine.currentTime - 1.25) < 0.05)
            #expect(audioEngine.speed == 1.25)
            #expect(audioEngine.currentEQGain == 7.5)
        }

        @Test func mediaServicesResetRebuildsOrphanedEngineAndPreservesItem() async throws {
            let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 4)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let audioEngine = AudioEngine()
            defer { audioEngine.cleanup() }
            audioEngine.configureAudioSession()
            audioEngine.setSpeed(1.5)
            audioEngine.setVolumeBoost(enabled: true, gainDB: 9.0)
            try audioEngine.replaceCurrentItem(with: audioURL, startTime: 1.5).get()

            let originalEngineID = try #require(audioEngine.currentEngineIdentity)
            audioEngine.playImmediately(atRate: 1.5)
            audioEngine.pause()

            // Simulate mediaserverd reset while paused.
            audioEngine.handleMediaServicesReset()

            let rebuiltEngineID = try #require(audioEngine.currentEngineIdentity)
            #expect(rebuiltEngineID != originalEngineID)
            #expect(audioEngine.isItemLoaded)
            #expect(audioEngine.isObservingConfigurationChanges)
            #expect(abs(audioEngine.currentTime - 1.5) < 0.05)
            #expect(audioEngine.speed == 1.5)
            #expect(audioEngine.currentEQGain == 9.0)

            // Playback on the rebuilt graph must start cleanly.
            audioEngine.play()
            #expect(audioEngine.isPlaying)
            #expect(audioEngine.isEngineRunning)
        }

        @Test func resumeAfterPauseReactivatesAudioSessionEvenWhenAlreadyConfigured() async throws {
            let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 4)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            var activations = 0
            let audioEngine = AudioEngine()
            defer { audioEngine.cleanup() }
            audioEngine.audioSessionActivator = { activations += 1 }
            audioEngine.configureAudioSession()
            #expect(activations == 1)

            try audioEngine.replaceCurrentItem(with: audioURL, startTime: 0.5).get()
            audioEngine.playImmediately(atRate: 1.0)
            #expect(activations == 2)

            // Active rate change while playing must not reactivate the session.
            audioEngine.playImmediately(atRate: 1.25)
            #expect(activations == 2)

            audioEngine.pause()
            audioEngine.play()
            #expect(activations == 3)
            #expect(audioEngine.isPlaying)
        }

        @Test func unrecoverableStartFailureSettlesPausedAndLaterPlayStillRecovers() async throws {
            let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 4)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let audioEngine = AudioEngine()
            let probe = RecoveryEngineProbe()
            audioEngine.delegate = probe
            defer {
                audioEngine.delegate = nil
                audioEngine.cleanup()
            }
            audioEngine.configureAudioSession()
            try audioEngine.replaceCurrentItem(with: audioURL, startTime: 1.0).get()

            var blockStart = true
            audioEngine.engineStartHandler = { engine in
                if blockStart {
                    throw NSError(domain: NSOSStatusErrorDomain, code: 561_015_905)
                }
                try engine.start()
            }

            audioEngine.playImmediately(atRate: 1.25)
            #expect(audioEngine.isPlaying == false)
            #expect(audioEngine.isEngineRunning == false)
            #expect(probe.unexpectedStops == 1)
            #expect(audioEngine.isItemLoaded)

            // Once the external blocker clears, the next tap plays immediately.
            blockStart = false
            audioEngine.playImmediately(atRate: 1.25)
            #expect(audioEngine.isPlaying)
            #expect(audioEngine.isEngineRunning)
            #expect(abs(audioEngine.currentTime - 1.0) < 0.05)
        }
    }

    @MainActor
    private final class RecoveryEngineProbe: AudioEngineDelegate {
        var unexpectedStops = 0
        func audioEngineDidUpdateTime(_ engine: AudioEngine, currentTime: TimeInterval) {}
        func audioEngineDidPlayToEnd(_ engine: AudioEngine) {}
        func audioEngineInterruptionBegan(_ engine: AudioEngine) {}
        func audioEngineInterruptionEnded(_ engine: AudioEngine, shouldResume: Bool) {}
        func audioEngineOutputDeviceDisconnected(_ engine: AudioEngine) {}
        func audioEngineDidStopUnexpectedly(_ engine: AudioEngine) { unexpectedStops += 1 }
    }
#endif
