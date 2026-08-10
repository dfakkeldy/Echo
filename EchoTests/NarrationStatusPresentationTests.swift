// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationStatusPresentationTests {
    struct PrecedenceCase: Sendable {
        let render: NarrationRenderActivity
        let playback: NarrationPlaybackActivity
        let expectedPrimary: String
    }

    static let activeStateCases = [
        PrecedenceCase(
            render: .planning, playback: .notStarted,
            expectedPrimary: "Planning narration"),
        PrecedenceCase(
            render: .heldByBackpressure(nil), playback: .notStarted,
            expectedPrimary: "Rendering paused while playback catches up"),
        PrecedenceCase(
            render: .rendering(renderUnit),
            playback: .resuming(chapterDisplayNumber: 3),
            expectedPrimary: "Resuming chapter 3"),
        PrecedenceCase(
            render: .rendering(renderUnit),
            playback: .loading(chapterDisplayNumber: 3),
            expectedPrimary: "Loading chapter 3"),
        PrecedenceCase(
            render: .rendering(renderUnit), playback: .stopped,
            expectedPrimary: "Narration stopped"),
        PrecedenceCase(
            render: .rendering(renderUnit), playback: .notStarted,
            expectedPrimary: "Rendering chapter 4 with Ava"),
    ]

    static let renderUnit = NarrationRenderUnitStatus(
        chapterDisplayNumber: 4, segmentIndex: 0,
        voiceID: VoiceID("af_heart"), completedBlocks: 8,
        totalBlocks: 19, startedAt: Date(timeIntervalSince1970: 200),
        lastProgressAt: Date(timeIntervalSince1970: 200))

    @Test func activeStatePrecedenceIsExplicit() {
        for testCase in Self.activeStateCases {
            var snapshot = NarrationStatusSnapshot()
            snapshot.render = testCase.render
            snapshot.playback = testCase.playback

            let value = NarrationStatusFormatter.presentation(
                for: snapshot, hasSession: true,
                now: Date(timeIntervalSince1970: 200))

            #expect(value?.primaryText == testCase.expectedPrimary)
        }
    }

    @Test func combinesPlayingRenderingAndBuffer() {
        let now = Date(timeIntervalSince1970: 200)
        var snapshot = NarrationStatusSnapshot()
        snapshot.playback = .playing(chapterDisplayNumber: 2)
        snapshot.render = .rendering(
            NarrationRenderUnitStatus(
                chapterDisplayNumber: 4, segmentIndex: 0,
                voiceID: VoiceID("af_heart"), completedBlocks: 8,
                totalBlocks: 19, startedAt: now, lastProgressAt: now))
        snapshot.buffer = NarrationBufferStatus(
            totalSegments: 8, queuedSegments: 3, currentPlaybackIndex: 1)

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: now)
        #expect(value?.primaryText == "Playing chapter 2")
        #expect(
            value?.secondaryText
                == "Rendering chapter 4, segment 1 · block 8 of 19 · Ava · 42% · 1 ready ahead")
        #expect(value?.progress == 8.0 / 19.0)
        #expect(
            value?.lockScreenSubtitle
                == "Playing chapter 2. Rendering chapter 4, segment 1 · block 8 of 19 · Ava · 42% · 1 ready ahead")
    }

    @Test func queueWaitOutranksGenericPause() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.playback = .waitingForRender(chapterDisplayNumber: 3)
        snapshot.render = .rendering(
            NarrationRenderUnitStatus(
                chapterDisplayNumber: 3, segmentIndex: 0,
                voiceID: VoiceID("af_heart"), completedBlocks: 5,
                totalBlocks: 7, startedAt: .distantPast, lastProgressAt: .distantPast))
        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)
        #expect(value?.primaryText == "Waiting for chapter 3")
        #expect(
            value?.secondaryText
                == "Rendering segment 1 · block 5 of 7 · Ava · 71%")
        #expect(
            value?.lockScreenSubtitle
                == "Waiting for chapter 3. Rendering segment 1 · block 5 of 7 · Ava · 71%")
    }

    @Test func modelDownloadLockScreenSubtitleIncludesActivityAndProgress() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .downloadingModel(
            receivedBytes: 134_000_000,
            totalBytes: 163_234_740)

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)

        #expect(value?.primaryText == "Downloading narration model")
        #expect(value?.secondaryText == "134 of 163 MB · 82%")
        #expect(
            value?.lockScreenSubtitle
                == "Downloading narration model. 134 of 163 MB · 82%")
    }

    @Test func modelLoadingLockScreenSubtitleIncludesActivity() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .loadingModel(startedAt: Date(timeIntervalSince1970: 100))

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true,
            now: Date(timeIntervalSince1970: 101.2))

        #expect(value?.primaryText == "Loading narration model")
        #expect(value?.secondaryText == "1.2s elapsed")
        #expect(value?.lockScreenSubtitle == "Loading narration model. 1.2s elapsed")
    }

    @Test func heldRenderPreservesUnitDiagnostics() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .heldByBackpressure(Self.renderUnit)

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true,
            now: Date(timeIntervalSince1970: 200))

        #expect(value?.primaryText == "Rendering paused while playback catches up")
        #expect(
            value?.secondaryText
                == "Rendering chapter 4, segment 1 · block 8 of 19 · Ava · 42%")
        #expect(value?.progress == 8.0 / 19.0)
    }

    @Test func resumingAndStoppedPlaybackKeepActiveRenderDetail() {
        for (playback, primary) in [
            (NarrationPlaybackActivity.resuming(chapterDisplayNumber: 3), "Resuming chapter 3"),
            (.stopped, "Narration stopped"),
        ] {
            var snapshot = NarrationStatusSnapshot()
            snapshot.render = .rendering(Self.renderUnit)
            snapshot.playback = playback

            let value = NarrationStatusFormatter.presentation(
                for: snapshot, hasSession: true,
                now: Date(timeIntervalSince1970: 200))

            #expect(value?.primaryText == primary)
            #expect(
                value?.secondaryText
                    == "Rendering chapter 4, segment 1 · block 8 of 19 · Ava · 42%")
        }
    }

    @Test func loadingPlaybackOutranksRenderingAndKeepsRenderDetail() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .rendering(Self.renderUnit)
        snapshot.playback = .loading(chapterDisplayNumber: 3)

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true,
            now: Date(timeIntervalSince1970: 200))

        #expect(value?.primaryText == "Loading chapter 3")
        #expect(
            value?.secondaryText
                == "Rendering chapter 4, segment 1 · block 8 of 19 · Ava · 42%")
        #expect(value?.progress == 8.0 / 19.0)
        #expect(value?.systemImage == "arrow.clockwise")
        #expect(value?.showsActivity == true)
    }

    @Test func completedRenderLoadingAndResumingShowActivity() {
        for (playback, primary) in [
            (NarrationPlaybackActivity.loading(chapterDisplayNumber: 3), "Loading chapter 3"),
            (.resuming(chapterDisplayNumber: 3), "Resuming chapter 3"),
        ] {
            var snapshot = NarrationStatusSnapshot()
            snapshot.render = .complete
            snapshot.playback = playback

            let value = NarrationStatusFormatter.presentation(
                for: snapshot, hasSession: true, now: .distantPast)

            #expect(value?.primaryText == primary)
            #expect(value?.secondaryText == "All chapters rendered")
            #expect(value?.systemImage == "arrow.clockwise")
            #expect(value?.showsActivity == true)
        }
    }

    @Test func reportsExactDecimalMegabytes() {
        #expect(
            NarrationStatusFormatter.megabyteText(
                receivedBytes: 134_000_000, totalBytes: 163_234_740)
                == "134 of 163 MB")
    }

    @Test func reportsLongBlockWithoutCallingItFailed() {
        let start = Date(timeIntervalSince1970: 100)
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .rendering(
            NarrationRenderUnitStatus(
                chapterDisplayNumber: 1, segmentIndex: 0,
                voiceID: VoiceID("af_heart"), completedBlocks: 7,
                totalBlocks: 19, startedAt: start, lastProgressAt: start))
        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true,
            now: Date(timeIntervalSince1970: 134))
        #expect(value?.secondaryText == "Still synthesizing block 8 · no update for 34s")
        #expect(value?.isFailure == false)
    }

    @Test func reportsBlockedRenderAsFailure() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .blocked(message: "Model unavailable")

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)

        #expect(value?.primaryText == "Narration unavailable")
        #expect(value?.secondaryText == "Model unavailable")
        #expect(value?.isFailure == true)
    }

    @Test func allRenderedPlaybackAddsReadyDetail() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .complete
        snapshot.playback = .playing(chapterDisplayNumber: 2)

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)

        #expect(value?.primaryText == "Playing chapter 2")
        #expect(value?.secondaryText == "All chapters rendered")
    }

    @Test func terminalPlaybackOutranksCompletedRender() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .complete
        snapshot.playback = .completed

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)

        #expect(value?.primaryText == "Playback completed")
    }

    @Test func stoppedPlaybackOutranksCompletedRender() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .complete
        snapshot.playback = .stopped

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)

        #expect(value?.primaryText == "Narration stopped")
    }

    @Test func cancelledRenderIsTerminal() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .cancelled

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)

        #expect(value?.primaryText == "Narration cancelled")
    }
}
