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
        s.reset()
        #expect(s.phase == .idle)
        #expect(s.progress == 0)
    }
}
