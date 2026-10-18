// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Regression guards for the headphone-connect bug.
    ///
    /// AVAudioEngine stops *itself* when the audio hardware reconfigures — most
    /// often when an output device connects mid-book — and nothing in Echo used
    /// to observe that. `isPlaying` was left true over a stopped engine, so the
    /// transport kept showing a pause button while nothing played, and the first
    /// tap only "paused" an already-stopped engine: playback took two presses to
    /// come back. The existing route observer never covered this, because it
    /// only handles `.oldDeviceUnavailable` — a device leaving, not arriving.
    @MainActor
    @Suite struct AudioEngineConfigurationChangeTests {

        /// The bug itself: the notification has to be observed at all.
        @Test func buildingTheGraphArmsTheConfigurationChangeObserver() {
            let engine = AudioEngine()
            defer { engine.cleanup() }
            #expect(engine.isObservingConfigurationChanges == false)

            engine.configureAudioSession()

            #expect(engine.isObservingConfigurationChanges)
        }

        /// `stop()` tears down the route and interruption observers, and `play()`
        /// re-arms them through `configureAudioSession()`. The configuration
        /// observer deliberately does *not* follow that pattern: the underlying
        /// AVAudioEngine instance survives `stop()`, so `configureEngineGraph()`
        /// early-returns and would never re-register it. Moving the teardown into
        /// `stop()` would silently strip headphone-connect recovery from every
        /// book resumed after a stop.
        @Test func observerSurvivesStopSoResumedPlaybackStaysCovered() {
            let engine = AudioEngine()
            defer { engine.cleanup() }
            engine.configureAudioSession()

            engine.stop()

            #expect(engine.isObservingConfigurationChanges)
        }

        /// Paired with `configureEngineGraph()`, which `cleanup()` undoes.
        @Test func cleanupTearsDownTheObserver() {
            let engine = AudioEngine()
            engine.configureAudioSession()

            engine.cleanup()

            #expect(engine.isObservingConfigurationChanges == false)
        }

        /// A reconfiguration while paused must stay a no-op — the next `play()`
        /// restarts a stopped engine on its own. This guards the direction of the
        /// fix: the point is that audio *follows* the new route, so regressing
        /// this into an unconditional pause would trade a lying button for a
        /// book that stops every time headphones connect.
        ///
        /// `awaitingNarrationChapter` is the sentinel: any pause clears it.
        @Test func configurationChangeWhilePausedLeavesTheTransportAlone() {
            let controller = PlaybackController()
            defer { controller.audioEngine.cleanup() }
            controller.audioEngine.configureAudioSession()
            controller.state.awaitingNarrationChapter = true

            controller.audioEngine.handleConfigurationChange()

            #expect(controller.state.awaitingNarrationChapter)
            #expect(controller.audioEngine.isPlaying == false)
        }

        /// When the engine cannot be brought back, the transport must settle into
        /// a real pause instead of sitting on a pause button over a dead engine.
        /// `pause()` carries the full state update — Now Playing, watch sync,
        /// pause timestamp — which is what makes the button honest again.
        @Test func unexpectedEngineStopDrivesARealPause() {
            let controller = PlaybackController()
            defer { controller.audioEngine.cleanup() }
            controller.state.isPlaying = true
            controller.state.awaitingNarrationChapter = true

            controller.audioEngineDidStopUnexpectedly(controller.audioEngine)

            #expect(controller.state.isPlaying == false)
            #expect(controller.state.awaitingNarrationChapter == false)
            #expect(controller.state.pauseTimestamp != nil)
        }
    }
#endif
