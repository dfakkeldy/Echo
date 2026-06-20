// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@Suite struct ImportedBookSourceTests {
    private func track(_ id: String, _ path: String, sort: Int, duration: Double = 60)
        -> TrackRecord
    {
        TrackRecord(
            id: id, audiobookID: "bk", title: "Track \(sort)", duration: duration,
            filePath: path, isEnabled: true, sortOrder: sort, playlistPosition: nil,
            narrationVoice: nil)
    }
    private func chapter(_ title: String, _ start: Double, _ end: Double, sort: Int)
        -> ChapterRecord
    {
        ChapterRecord(
            id: nil, audiobookID: "bk", title: title, startSeconds: start,
            endSeconds: end, isEnabled: true, sortOrder: sort, playlistPosition: nil)
    }

    /// Single source file + N chapters → N items slicing the file by time range.
    @Test func singleFileBecomesTimeRangeSlices() {
        let tracks = [track("t0", "file:///b.m4b", sort: 0, duration: 300)]
        let chapters = [
            chapter("One", 0, 120, sort: 0),
            chapter("Two", 120, 300, sort: 1),
        ]
        let items = ImportedBookSource.makeItems(tracks: tracks, chapters: chapters)
        #expect(items.map(\.title) == ["One", "Two"])
        #expect(items.allSatisfy { $0.url == URL(string: "file:///b.m4b") })
        #expect(items[0].timeRange?.start.seconds == 0)
        #expect(items[1].timeRange?.start.seconds == 120)
        #expect(items[1].timeRange?.duration.seconds == 180)
    }

    /// Multiple files → one whole-file item per track, titled by chapter when counts align.
    @Test func multiFileBecomesWholeFileItems() {
        let tracks = [
            track("t0", "file:///a.mp3", sort: 0),
            track("t1", "file:///b.mp3", sort: 1),
        ]
        let chapters = [
            chapter("Intro", 0, 60, sort: 0),
            chapter("Body", 60, 120, sort: 1),
        ]
        let items = ImportedBookSource.makeItems(tracks: tracks, chapters: chapters)
        #expect(items.map(\.title) == ["Intro", "Body"])
        #expect(items.map(\.url) == [URL(string: "file:///a.mp3"), URL(string: "file:///b.mp3")])
        #expect(items.allSatisfy { $0.timeRange == nil })
    }

    /// Multiple files but no usable chapters → fall back to track titles.
    @Test func multiFileFallsBackToTrackTitles() {
        let tracks = [track("t0", "file:///a.mp3", sort: 0), track("t1", "file:///b.mp3", sort: 1)]
        let items = ImportedBookSource.makeItems(tracks: tracks, chapters: [])
        #expect(items.map(\.title) == ["Track 0", "Track 1"])
    }
}
