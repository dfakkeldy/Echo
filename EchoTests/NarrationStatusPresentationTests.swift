// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationStatusPresentationTests {
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
        #expect(value?.secondaryText == "Rendering chapter 4 · 42% · 1 ready ahead")
        #expect(value?.progress == 8.0 / 19.0)
        #expect(value?.lockScreenSubtitle == "Rendering chapter 4 · 42% · 1 ready ahead")
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
        #expect(value?.secondaryText == "Rendering 71%")
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
}
