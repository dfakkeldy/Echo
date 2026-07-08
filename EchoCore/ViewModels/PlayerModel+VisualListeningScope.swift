// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension PlayerModel {
    var currentTrackChapterIndices: Set<Int>? {
        let currentTracks = tracks
        let activeIndex = currentIndex
        var playingChapterIndex: Int?
        if currentTracks.indices.contains(activeIndex) {
            playingChapterIndex = NarrationFileNaming.chapterIndex(
                fromFileName: currentTracks[activeIndex].url.lastPathComponent
            )
        }
        return ReaderActiveBlockResolver.trackChapterScope(
            trackCount: currentTracks.count,
            isMultiM4B: isMultiM4B,
            currentIndex: activeIndex,
            playingChapterIndex: playingChapterIndex
        )
    }

    var currentTrackSegmentKey: String? {
        let currentTracks = tracks
        let activeIndex = currentIndex
        guard currentTracks.indices.contains(activeIndex),
            let location = NarrationFileNaming.segmentLocation(
                fromFileName: currentTracks[activeIndex].url.lastPathComponent
            )
        else { return nil }

        return ReaderActiveBlockResolver.segmentKey(
            forChapter: location.chapterIndex,
            segment: location.segmentIndex
        )
    }
}
