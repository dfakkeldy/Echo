// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for macOS reader-interaction parity in MacReaderFeedView.
/// The `Echo macOS` target is not compiled into EchoTests, so we assert against
/// source text via `MacSource`. Alignment work goes through the shared,
/// macOS-clean `AlignmentService`.
struct MacReaderParityTests {

    @Test func readerHasAlignmentContextMenu() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("alignmentMenu"),
            "The reader cards must offer a right-click alignment context menu.")
        #expect(
            src.contains("\"Align to Now\""),
            "The alignment menu must offer Align to Now (and the other per-block actions).")
    }

    @Test func alignmentRoutesThroughSharedService() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("AlignmentService(db:"),
            "Manual alignment must use the shared AlignmentService, not a macOS reimplementation.")
        #expect(
            src.contains("moveBlockToCurrentTime") && src.contains("resetAlignment"),
            "The menu must wire the AlignmentService editing entry points (move/hide/erase/reset).")
    }

    @Test func alignmentReloadsFeed() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("performAlignment("),
            "A performAlignment helper must apply the edit and reload the feed.")
    }
}
