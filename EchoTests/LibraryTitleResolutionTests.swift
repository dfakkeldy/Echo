// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct LibraryTitleResolutionTests {
    @Test func albumTagWinsOverTrackTitle() {
        #expect(
            LibraryScanner.resolveBookTitle(
                album: "The High-Conflict Couple",
                track: "01 - The High-Conflict Couple: Chapter 1",
                fallback: "Folder"
            ) == "The High-Conflict Couple")
    }

    @Test func fallsBackToTrackThenFolder() {
        #expect(
            LibraryScanner.resolveBookTitle(album: nil, track: "Some Book", fallback: "Folder")
                == "Some Book")
        #expect(
            LibraryScanner.resolveBookTitle(album: "", track: "", fallback: "Folder Name")
                == "Folder Name")
    }
}
