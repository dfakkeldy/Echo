// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Derives chapter-relative sidecar offsets from the exact current narration
/// plan. Persisted orphan rows and stale mutable sort orders are deliberately
/// ignored; only expected plan track IDs participate, in plan order.
nonisolated enum NarrationPlanTrackOffsets {
    static func chapterOffsets(
        audiobookID: String,
        chapters: [NarrationChapterRenderPlan],
        tracks: [TrackRecord],
        expectedFilePathsByTrackID: [String: String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Int: TimeInterval]? {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var offsets: [Int: TimeInterval] = [:]
        var running: TimeInterval = 0

        for chapter in chapters {
            let trackID = NarrationFileNaming.trackID(
                audiobookID: audiobookID,
                chapterIndex: chapter.chapterIndex,
                sourceChapterKey: chapter.sourceChapterKey,
                segmentIndex: nil)
            guard let expectedPath = expectedFilePathsByTrackID[trackID],
                let track = tracksByID[trackID],
                track.audiobookID == audiobookID,
                track.filePath == expectedPath,
                track.narrationVoice == chapter.voice.rawValue,
                track.duration.isFinite,
                track.duration > 0,
                fileExists(expectedPath),
                offsets[chapter.chapterIndex] == nil
            else {
                return nil
            }
            offsets[chapter.chapterIndex] = running
            running += track.duration
        }
        return offsets
    }
}
