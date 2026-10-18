// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One chapter boundary in the exported video's global timeline. Produced by
/// `VideoExportService`'s audio-assembly loop; formatted here.
nonisolated struct SlideshowChapterMark: Equatable, Sendable {
    let startTime: TimeInterval
    let title: String
}

/// Pure text formatting for the sidecar `.srt` and `.chapters.txt` outputs.
/// SRT timestamps are `HH:MM:SS,mmm`; chapters lines use the YouTube
/// description convention (`HH:MM:SS Title`).
nonisolated enum SRTFormatter {
    static func timestamp(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let totalMilliseconds = Int((clamped * 1000).rounded(.down))
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        return String(
            format: "%02d:%02d:%02d,%03d",
            totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, milliseconds)
    }

    static func chapterTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time).rounded(.down))
        return String(
            format: "%02d:%02d:%02d",
            totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }

    static func srtDocument(cues: [SlideshowSRTCue]) -> String {
        guard !cues.isEmpty else { return "" }
        return cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(timestamp(cue.startTime)) --> \(timestamp(cue.endTime))
            \(cue.text)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    static func chaptersDocument(marks: [SlideshowChapterMark]) -> String {
        guard !marks.isEmpty else { return "" }
        return marks.map { "\(chapterTimestamp($0.startTime)) \($0.title)" }
            .joined(separator: "\n") + "\n"
    }
}
