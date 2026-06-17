// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Source-scanning structural tests for the macOS Playback Options popover,
/// using the shared `MacSource` resolver (groundwork #3).
struct MacPlaybackOptionsSheetTests {

    @Test("MacPlaybackOptionsSheet declares the struct")
    func declaresStruct() throws {
        let src = try MacSource.read("Views/MacPlaybackOptionsSheet.swift")
        #expect(src.contains("struct MacPlaybackOptionsSheet: View"))
    }

    @Test("MacPlaybackOptionsSheet drives the live MacPlayerModel controls")
    func drivesLiveControls() throws {
        let src = try MacSource.read("Views/MacPlaybackOptionsSheet.swift")
        #expect(src.contains("player.playbackRate"))
        #expect(src.contains("player.loopMode"))
        #expect(src.contains("player.skipInterval"))
        #expect(src.contains("player.isVolumeBoostEnabled"))
    }

    @Test("MacPlaybackOptionsSheet uses a segmented loop Picker")
    func loopIsSegmented() throws {
        let src = try MacSource.read("Views/MacPlaybackOptionsSheet.swift")
        #expect(src.contains(".pickerStyle(.segmented)"))
    }

    @Test("MacTriPaneView removed the inline speed Picker and routes to the popover")
    func triPaneRoutesToPopover() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(src.contains("MacPlaybackOptionsSheet"))
        #expect(src.contains(".popover"))
        // The old inline hardcoded speed Picker tags are gone (robust token).
        #expect(!src.contains("Text(\"1×\").tag(Float(1.0))"))
    }
}
