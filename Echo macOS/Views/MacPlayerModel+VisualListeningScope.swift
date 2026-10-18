// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension MacPlayerModel {
    var currentTrackChapterIndices: Set<Int>? {
        ReaderActiveBlockResolver.trackChapterScope(
            trackCount: tracks.count,
            isMultiM4B: false,
            currentIndex: currentTrackIndex,
            playingChapterIndex: nil
        )
    }

    var currentTrackSegmentKey: String? {
        nil
    }
}
