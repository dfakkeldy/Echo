// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct TabSelectionTests {
    @Test func tabCasesReflectPlayerReaderAndLibraryOnly() {
        // Stats moved to the More menu (presented as a sheet), so it must NOT be a
        // bottom tab. This guard also proves a persisted "stats" rawValue decodes
        // to nil, so tab-restore falls back safely.
        #expect(TabSelection.allCases.map(\.rawValue) == ["nowPlaying", "read", "library"])
        #expect(TabSelection(rawValue: "stats") == nil)
    }

    @Test func libraryCaseHasIconAndLabel() {
        #expect(TabSelection.library.icon == "books.vertical")
        #expect(TabSelection.library.label == "Library")
        #expect(TabSelection.allCases.contains(.library))
    }
}
