// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum NarrationSegmentCache {
    struct CachedChapter: Equatable, Sendable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        let segmentURLs: [URL]
    }

    static func cachedChapter(
        for plannedSegments: [NarrationSegmentPlanner.PlannedSegment],
        files: [URL],
        audiobookID: String,
        voice: VoiceID
    ) -> CachedChapter? {
        guard let first = plannedSegments.first else { return nil }
        let orderedSegments = plannedSegments.sorted { $0.segmentIndex < $1.segmentIndex }
        let urlsByName = Dictionary(files.map { ($0.lastPathComponent, $0) }) { existing, _ in
            existing
        }
        var segmentURLs: [URL] = []

        for (expectedIndex, segment) in orderedSegments.enumerated() {
            guard segment.chapterIndex == first.chapterIndex else { return nil }
            guard segment.chapterDisplayNumber == first.chapterDisplayNumber else { return nil }
            guard segment.segmentIndex == expectedIndex else { return nil }

            let name = NarrationFileNaming.segmentFileName(
                audiobookID: audiobookID,
                chapterIndex: segment.chapterIndex,
                segmentIndex: segment.segmentIndex,
                voice: voice)
            guard let url = urlsByName[name] else { return nil }
            segmentURLs.append(url)
        }

        return CachedChapter(
            chapterIndex: first.chapterIndex,
            chapterDisplayNumber: first.chapterDisplayNumber,
            segmentURLs: segmentURLs)
    }
}
