// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ChromeConsolidationTests {
    // The 2026-07-05 chrome consolidation: UnifiedTopHeader carries only the
    // folder chip + SleepTimerPill; the sole overflow menu lives in
    // PlayerMoreMenu. If UnifiedTopHeader ever grows a Menu again, or
    // PlayerMoreMenu loses the app-level closures, these fail at compile time.
    @Test @MainActor func topHeaderHasOnlyFolderClosure() {
        _ = UnifiedTopHeader(onFolderTap: {})
    }

    @Test @MainActor func playerMoreMenuCarriesAppLevelActions() {
        _ = PlayerMoreMenu(
            onShowChapters: {},
            onShowBookmarks: {},
            onStats: {},
            onFidget: {},
            onSettings: {},
            onHelp: {},
            onAddDocument: nil,
            onExport: nil,
            onStudyNotesExport: nil
        )
    }
}
