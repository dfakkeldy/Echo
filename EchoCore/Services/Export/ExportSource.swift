// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// One chapter's worth of source audio plus the title to stamp on its marker.
/// `timeRange == nil` means "use the whole file" (narration cache files and
/// multi-file imported books); a non-nil range slices one source file
/// (a single-file m4b carved into its embedded chapters).
nonisolated struct ExportItem: Equatable {
    let title: String
    let url: URL
    let timeRange: CMTimeRange?
    let emitsChapterMarker: Bool

    init(
        title: String,
        url: URL,
        timeRange: CMTimeRange?,
        emitsChapterMarker: Bool = true
    ) {
        self.title = title
        self.url = url
        self.timeRange = timeRange
        self.emitsChapterMarker = emitsChapterMarker
    }
}

/// Where an export's ordered audio comes from. Narrated books read per-chapter
/// cache files; imported books read the original on-disk track files. Both
/// resolve to the same `[ExportItem]` the service concatenates + chapterises.
protocol ExportSource {
    func items() async throws -> [ExportItem]
}
