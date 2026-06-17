// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct NarrationTrackOrderingTests {
    @Test func ordersBySortOrderAndMapsFilePaths() {
        let tracks = [
            TrackRecord(
                id: "b", audiobookID: "x", title: "2", duration: 1, filePath: "/b.m4a",
                isEnabled: true, sortOrder: 1, playlistPosition: nil, narrationVoice: "ava"),
            TrackRecord(
                id: "a", audiobookID: "x", title: "1", duration: 1, filePath: "/a.m4a",
                isEnabled: true, sortOrder: 0, playlistPosition: nil, narrationVoice: "ava"),
        ]
        #expect(
            NarrationTrackOrdering.orderedFileURLs(tracks).map(\.lastPathComponent)
                == ["a.m4a", "b.m4a"])
    }

    @Test func excludesDisabledTracks() {
        let tracks = [
            TrackRecord(
                id: "a", audiobookID: "x", title: "1", duration: 1, filePath: "/a.m4a",
                isEnabled: true, sortOrder: 0, playlistPosition: nil, narrationVoice: "ava"),
            TrackRecord(
                id: "b", audiobookID: "x", title: "2", duration: 1, filePath: "/b.m4a",
                isEnabled: false, sortOrder: 1, playlistPosition: nil, narrationVoice: "ava"),
        ]
        #expect(
            NarrationTrackOrdering.orderedFileURLs(tracks).map(\.lastPathComponent) == ["a.m4a"])
    }
}
