// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural (source-scanning) tests for the macOS tri-pane player bar.
///
/// These assert on the *text* of `Echo macOS/Views/MacTriPaneView.swift` rather
/// than importing the macOS view (the test bundle targets iOS), reusing the
/// shared `MacSource` resolver (G2) to reach the `Echo macOS/` target folder.
struct MacChapterNavLayoutTests {

    @Test func macPlayerBarUsesChapterChevronsNotTrackLabel() throws {
        let source = try MacSource.read("Views/MacTriPaneView.swift")

        #expect(
            source.contains("chevron.left") && source.contains("chevron.right"),
            "The macOS player bar should use chevron buttons for chapter navigation."
        )
        #expect(
            source.contains("player.previousChapter()")
                && source.contains("player.nextChapter()"),
            "The macOS chapter chevrons should call previousChapter()/nextChapter()."
        )
        #expect(
            source.contains("Previous chapter") && source.contains("Next chapter"),
            "The macOS chapter chevrons should carry .help()/.accessibilityLabel tooltips."
        )
        #expect(
            source.contains("player.chapters.count >= 2"),
            "The macOS player bar should gate the chevron bar on having 2+ chapters and fall back to the track label otherwise."
        )
    }
}
