// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct NowPlayingRemoteSeekTests {
    private func chapter(_ index: Int, start: TimeInterval, end: TimeInterval) -> Chapter {
        Chapter(index: index, title: "Chapter \(index + 1)", startSeconds: start, endSeconds: end)
    }

    @Test("remote position commands are chapter-relative when Now Playing is chapter-scoped")
    func remoteSeekAddsCurrentChapterStart() {
        let chapters = [
            chapter(0, start: 0, end: 60),
            chapter(1, start: 60, end: 120),
            chapter(2, start: 120, end: 220),
        ]

        let target = PlaybackController.remoteCommandSeekTarget(
            positionTime: 30,
            chapters: chapters,
            currentChapterIndex: 2,
            durationSeconds: 220
        )

        #expect(target == 150)
    }

    @Test("remote position commands stay absolute when Now Playing is track-scoped")
    func remoteSeekStaysAbsoluteWithoutCurrentChapter() {
        let target = PlaybackController.remoteCommandSeekTarget(
            positionTime: 90,
            chapters: [],
            currentChapterIndex: nil,
            durationSeconds: 220
        )

        #expect(target == 90)
    }

    @Test("remote position commands clamp to the active Now Playing scope")
    func remoteSeekClampsToScope() {
        let chapters = [
            chapter(0, start: 0, end: 60),
            chapter(1, start: 60, end: 120),
            chapter(2, start: 120, end: 220),
        ]

        let chapterScopedTarget = PlaybackController.remoteCommandSeekTarget(
            positionTime: 500,
            chapters: chapters,
            currentChapterIndex: 2,
            durationSeconds: 220
        )
        let trackScopedTarget = PlaybackController.remoteCommandSeekTarget(
            positionTime: 500,
            chapters: [],
            currentChapterIndex: nil,
            durationSeconds: 220
        )

        #expect(chapterScopedTarget == 220)
        #expect(trackScopedTarget == 220)
    }
}
