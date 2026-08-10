// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationStateTests {
    @Test func startsIdleAndNotRunning() {
        let s = NarrationState()
        #expect(s.phase == .idle)
        #expect(s.isRunning == false)
    }

    @Test func preparingChapterIsRunning() {
        let s = NarrationState()
        s.update(phase: .preparingChapter, progress: 0.1, statusMessage: "Preparing chapter…")
        #expect(s.isRunning == true)
        #expect(s.progress == 0.1)
    }

    @Test func failSetsFailedAndMessage() {
        let s = NarrationState()
        s.fail("boom")
        #expect(s.phase == .failed)
        #expect(s.errorMessage == "boom")
        #expect(s.isRunning == false)
    }

    @Test func resetReturnsToIdle() {
        let s = NarrationState()
        s.update(phase: .renderingAhead, progress: 0.5, statusMessage: "x")
        s.beginSession(defaultVoiceID: VoiceID("af_heart"))
        _ = s.reportModelDownload(receivedBytes: 5, totalBytes: 100)
        s.reset()
        #expect(s.phase == .idle)
        #expect(s.progress == 0)
        #expect(s.snapshot == NarrationStatusSnapshot())
        #expect(s.events.isEmpty)
        #expect(s.snapshot.defaultVoiceID == nil)
        #expect(s.reportModelDownload(receivedBytes: 1, totalBytes: 100))
    }

    @MainActor
    @Test func preparingEngineCountsAsRunning() {
        let s = NarrationState()
        s.update(phase: .preparingEngine, progress: 0.2, statusMessage: "Compiling…")
        #expect(s.phase == .preparingEngine)
        #expect(s.isRunning)
    }

    @Test func activeRenderPreparationMakesStateRunning() {
        let s = NarrationState()
        s.beginSession(defaultVoiceID: VoiceID("af_heart"))
        #expect(!s.isRunning)

        s.transitionRender(to: .planning, event: nil)
        #expect(s.isRunning)

        s.transitionRender(to: .modelReady, event: nil)
        #expect(!s.isRunning)
    }
}
