// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationStateTests {
    @Test func startsIdleAndNotRunning() {
        let s = NarrationState()
        #expect(s.phase == .idle)
        #expect(s.isRunning == false)
    }

    @Test func structuredRenderActivityProjectsCompatibilityPhase() {
        let s = NarrationState()

        s.transitionRender(to: .planning, event: nil)
        #expect(s.phase == .preparingChapter)
        #expect(s.isRunning == true)

        s.transitionRender(to: .checkingModel(expectedBytes: 100), event: nil)
        #expect(s.phase == .preparingEngine)

        let now = Date(timeIntervalSince1970: 100)
        s.transitionRender(
            to: .rendering(
                NarrationRenderUnitStatus(
                    chapterDisplayNumber: 2,
                    segmentIndex: 0,
                    voiceID: VoiceID("af_heart"),
                    completedBlocks: 1,
                    totalBlocks: 4,
                    startedAt: now,
                    lastProgressAt: now)),
            event: nil)
        s.transitionPlayback(to: .playing(chapterDisplayNumber: 1), event: nil)
        #expect(s.phase == .renderingAhead)
    }

    @Test func resetReturnsToIdle() {
        let s = NarrationState()
        s.beginSession(defaultVoiceID: VoiceID("af_heart"))
        s.transitionRender(to: .planning, event: nil)
        _ = s.reportModelDownload(receivedBytes: 5, totalBytes: 100)
        s.reset()
        #expect(s.phase == .idle)
        #expect(s.snapshot == NarrationStatusSnapshot())
        #expect(s.events.isEmpty)
        #expect(s.hasSession == false)
        #expect(s.snapshot.defaultVoiceID == nil)
        #expect(s.reportModelDownload(receivedBytes: 1, totalBytes: 100))
    }

    @Test func renderCompletionDoesNotCompletePlayback() {
        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))
        state.transitionPlayback(to: .playing(chapterDisplayNumber: 1), event: nil)
        state.transitionRender(to: .complete, event: nil)

        #expect(state.snapshot.render == .complete)
        #expect(state.snapshot.playback == .playing(chapterDisplayNumber: 1))
        #expect(state.phase == .idle)
        #expect(state.hasSession)
    }

    @Test func renderAndPlaybackCompletionProjectCompletedPhase() {
        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))
        state.transitionRender(to: .complete, event: nil)
        state.transitionPlayback(to: .completed, event: nil)

        #expect(state.phase == .completed)
        #expect(state.isRunning == false)
    }

    @Test func noTextBlockedAndFailureRemainVisible() {
        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))

        state.transitionRender(to: .noNarratableText, event: nil)
        #expect(state.hasSession)

        state.transitionRender(to: .blocked(message: "Narration limit reached"), event: nil)
        #expect(state.phase == .failed)
        #expect(state.hasSession)

        state.transitionRender(to: .failed(message: "Model unavailable"), event: nil)
        #expect(state.phase == .failed)
        #expect(state.hasSession)
    }

    @Test func activeRenderPreparationMakesStateRunning() {
        let s = NarrationState()
        s.beginSession(defaultVoiceID: VoiceID("af_heart"))
        #expect(s.isRunning == false)

        s.transitionRender(to: .planning, event: nil)
        #expect(s.isRunning)

        s.transitionRender(to: .modelReady, event: nil)
        #expect(s.phase == .preparingEngine)
        #expect(s.isRunning == false)
    }
}
