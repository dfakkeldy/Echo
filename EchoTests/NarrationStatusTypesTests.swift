// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationStatusTypesTests {
    @Test func playingAndRenderingRemainIndependent() {
        let state = NarrationState()
        let now = Date(timeIntervalSince1970: 100)
        state.beginSession(defaultVoiceID: VoiceID("af_heart"), at: now)
        state.transitionPlayback(
            to: .playing(chapterDisplayNumber: 2),
            event: .init(
                category: .playback, severity: .notice,
                message: "Playing chapter 2",
                developerMessage: "playback playing chapter=2"),
            at: now)
        state.transitionRender(
            to: .rendering(
                NarrationRenderUnitStatus(
                    chapterDisplayNumber: 4, segmentIndex: 0,
                    voiceID: VoiceID("af_heart"), completedBlocks: 8,
                    totalBlocks: 19, startedAt: now, lastProgressAt: now)),
            event: nil, at: now)

        #expect(state.snapshot.playback == .playing(chapterDisplayNumber: 2))
        guard case .rendering(let unit) = state.snapshot.render else {
            Issue.record("Expected rendering activity")
            return
        }
        #expect(unit.completedBlocks == 8)
        #expect(unit.totalBlocks == 19)
    }

    @Test func eventHistoryKeepsLatestTwoHundred() {
        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))
        for index in 0..<205 {
            state.record(
                .init(
                    category: .render, severity: .info,
                    message: "Block \(index)",
                    developerMessage: "render block=\(index)"))
        }
        #expect(state.events.count == 200)
        #expect(state.events.first?.message == "Block 5")
        #expect(state.events.last?.message == "Block 204")
    }

    @Test func downloadHistoryUsesFivePercentMilestones() {
        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))
        #expect(state.reportModelDownload(receivedBytes: 1, totalBytes: 100))
        #expect(!state.reportModelDownload(receivedBytes: 4, totalBytes: 100))
        #expect(state.reportModelDownload(receivedBytes: 5, totalBytes: 100))
        #expect(!state.reportModelDownload(receivedBytes: 9, totalBytes: 100))
        #expect(state.reportModelDownload(receivedBytes: 10, totalBytes: 100))
        #expect(state.events.filter { $0.category == .model }.count == 3)
    }
}
