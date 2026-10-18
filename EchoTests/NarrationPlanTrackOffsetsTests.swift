// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationPlanTrackOffsetsTests {
    @Test func reorderedPlanIgnoresStaleSortOrdersAndRemovedOrphanTracks() throws {
        let audiobookID = "anthology"
        let entryA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let entryB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let voice = VoiceID("af_heart")
        let chapterA = plan(index: 1, key: entryA, voice: voice)
        let chapterB = plan(index: 0, key: entryB, voice: voice)
        let trackAID = NarrationFileNaming.trackID(
            audiobookID: audiobookID, chapterIndex: 1,
            sourceChapterKey: entryA, segmentIndex: nil)
        let trackBID = NarrationFileNaming.trackID(
            audiobookID: audiobookID, chapterIndex: 0,
            sourceChapterKey: entryB, segmentIndex: nil)
        let trackA = track(
            id: trackAID, audiobookID: audiobookID, path: "/cache/a.m4a",
            duration: 10, sortOrder: 0, voice: voice)
        let trackB = track(
            id: trackBID, audiobookID: audiobookID, path: "/cache/b.m4a",
            duration: 20, sortOrder: 1_000, voice: voice)
        let orphan = track(
            id: "syn-anthology-removed", audiobookID: audiobookID,
            path: "/cache/orphan.m4a", duration: 999, sortOrder: -1, voice: voice)

        let offsets = try #require(
            NarrationPlanTrackOffsets.chapterOffsets(
                audiobookID: audiobookID,
                chapters: [chapterB, chapterA],
                tracks: [orphan, trackA, trackB],
                expectedFilePathsByTrackID: [
                    trackAID: trackA.filePath,
                    trackBID: trackB.filePath,
                ],
                fileExists: { _ in true }))

        #expect(offsets == [0: 0, 1: 20])
    }

    private func plan(index: Int, key: String, voice: VoiceID) -> NarrationChapterRenderPlan {
        NarrationChapterRenderPlan(
            chapterIndex: index, displayNumber: index + 1,
            sourceChapterKey: key, title: "Chapter", blocks: [], voice: voice)
    }

    private func track(
        id: String,
        audiobookID: String,
        path: String,
        duration: TimeInterval,
        sortOrder: Int,
        voice: VoiceID
    ) -> TrackRecord {
        TrackRecord(
            id: id, audiobookID: audiobookID, title: "Old", duration: duration,
            filePath: path, isEnabled: true, sortOrder: sortOrder,
            playlistPosition: nil, narrationVoice: voice.rawValue)
    }
}
