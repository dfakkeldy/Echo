// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct MacVisualListeningParityTests {
    @Test func triPaneHostsVisualListeningStageBesideReader() throws {
        let triPane = try MacSource.read("Views/MacTriPaneView.swift")

        #expect(
            triPane.contains("VisualListeningViewModel"),
            "MacTriPaneView should load visual-listening snapshots from the shared view model."
        )
        #expect(
            triPane.contains("MacVisualStageView("),
            "macOS should mount a visual listening stage in the center workspace."
        )
        #expect(
            triPane.contains("MacReaderFeedView()"),
            "The visual stage must augment the reader, not replace it."
        )
        #expect(
            triPane.contains("player.currentTime"),
            "The macOS stage should update from live playback time."
        )
        #expect(
            triPane.contains("player.currentTrackChapterIndices"),
            "The macOS stage should use the same track scope semantics as the reader."
        )
        #expect(
            triPane.contains("visualListeningViewModel?.hasVisualListeningContent == true"),
            "The macOS stage should only appear when both image and subtitle cues are available."
        )
        #expect(
            triPane.contains("snapshot.subtitleCue != nil"),
            "The macOS visual stage should only appear with a subtitle cue."
        )
    }

    @Test func macVisualStageKeepsSubtitlesTimingChoiceAndImageLoading() throws {
        let stage = try MacSource.read("Views/MacVisualStageView.swift")

        #expect(stage.contains("Image(nsImage: image)"))
        #expect(stage.contains("Picker(\"Image timing\""))
        #expect(stage.contains("Subtitle:"))
        #expect(stage.contains("Current figure"))
        #expect(stage.contains("WordTokenizer.wordRanges"))
        #expect(stage.contains("SafeFileName.fromAudiobookID"))
    }

    @Test func macTrackScopeUsesSharedResolver() throws {
        let scope = try MacSource.read("Views/MacPlayerModel+VisualListeningScope.swift")

        #expect(scope.contains("ReaderActiveBlockResolver.trackChapterScope"))
        #expect(scope.contains("currentTrackIndex"))
        #expect(scope.contains("isMultiM4B: false"))
    }
}
