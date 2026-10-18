// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum NarrationEntitlementCounter {
    static func renderedChapterCount(in tracks: [TrackRecord]) -> Int {
        let chapterIndices = tracks.compactMap { track -> Int? in
            guard track.narrationVoice != nil else { return nil }
            let fileName = URL(fileURLWithPath: track.filePath).lastPathComponent
            return NarrationFileNaming.chapterIndex(fromFileName: fileName)
                ?? NarrationFileNaming.chapterIndex(fromFileName: track.id)
        }
        return Set(chapterIndices).count
    }
}
