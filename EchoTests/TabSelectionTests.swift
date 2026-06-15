import Testing

@testable import Echo

@Suite struct TabSelectionTests {
    @Test func statsIsNoLongerATab() {
        // Stats moved to the More menu (presented as a sheet), so it must NOT be a
        // bottom tab. This guard also proves a persisted "stats" rawValue decodes
        // to nil, so tab-restore falls back safely.
        #expect(TabSelection.allCases.map(\.rawValue) == ["nowPlaying", "read", "timeline"])
        #expect(TabSelection(rawValue: "stats") == nil)
    }
}
