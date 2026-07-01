// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for the macOS Audiobookshelf integration (connect / browse /
/// download-to-play). The `Echo macOS` target is not compiled into EchoTests, so
/// we assert against source text via `MacSource`. The Mac UI drives the shared,
/// macOS-clean ABS services directly (the iOS PlayerModel+Audiobookshelf and ABS
/// views aren't part of the macOS target).
struct MacAudiobookshelfParityTests {

    @Test func connectsViaSharedService() throws {
        let src = try MacSource.read("Views/MacAudiobookshelfView.swift")
        #expect(
            src.contains("AudiobookshelfService(") && src.contains("ABSURLSession.make("),
            "macOS ABS connect must build the shared AudiobookshelfService over a trust-aware session."
        )
        #expect(
            src.contains("ABSServerDAO(db:") && src.contains(".login("),
            "Connect must authenticate and persist the server record via the shared DAO.")
        #expect(
            src.contains("untrustedCertificate"),
            "Connect must handle the self-signed certificate trust flow.")
    }

    @Test func browsesAndImports() throws {
        let src = try MacSource.read("Views/MacAudiobookshelfView.swift")
        #expect(
            src.contains(".libraries()") && src.contains(".allItems(") && src.contains(".search("),
            "The browser must list libraries/items and search via the shared service.")
        #expect(
            src.contains("ABSImportService(") && src.contains("prepareLocalFolder("),
            "Adding an item must download + import it via the shared ABSImportService.")
    }

    @Test func menuOpensAudiobookshelf() throws {
        let app = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            app.contains("requestAudiobookshelf"),
            "A File menu command must post .requestAudiobookshelf.")
        let triPane = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            triPane.contains("MacAudiobookshelfView(")
                && triPane.contains(".requestAudiobookshelf"),
            "MacTriPaneView must present the Audiobookshelf sheet and play the imported folder.")
    }

    @Test func syncsProgressViaIndependentService() throws {
        let src = try MacSource.read("Views/MacPlayerModel+Audiobookshelf.swift")
        #expect(
            src.contains("func makeAudiobookshelfService()") && src.contains("ABSServerDAO"),
            "MacPlayerModel must build its own independent AudiobookshelfService so sync keeps working when the Connect sheet is closed."
        )
        #expect(
            src.contains("func refreshABSSyncIdentity()")
                && src.contains("sourceType == \"audiobookshelf\""),
            "Sync identity must be cached from AudiobookDAO on book load.")
        #expect(
            src.contains("func maybePushABSProgress(")
                && src.contains("ABSProgressSync.shouldPush("),
            "Progress push must be throttled via the shared ABSProgressSync policy.")
        #expect(
            src.contains("func reconcileABSProgressOnLoad()")
                && src.contains("ABSProgressReconciler.decide("),
            "Load-time reconciliation must use the shared ABSProgressReconciler.")
    }

    /// Final-review Finding #1: `MacAudiobookshelfViewModel` (sheet-scoped) can switch or
    /// remove the active saved server with no signal to the long-lived `MacPlayerModel` — the
    /// two are wired together only via an `onPlay` closure (`MacTriPaneView`). Without a
    /// server-ID check, `makeAudiobookshelfService()`'s warm cache would keep returning a
    /// service for a stale/possibly-deleted server, silently pushing progress to the wrong
    /// place. Matches iOS's `PlayerModel+Audiobookshelf.makeAudiobookshelfService()` guard.
    @Test func invalidatesCachedServiceOnServerMismatch() throws {
        let src = try MacSource.read("Views/MacPlayerModel+Audiobookshelf.swift")
        #expect(
            src.contains("absServiceServerID == server.id"),
            "makeAudiobookshelfService() must compare the cached service's server ID against the currently-active server before trusting the cache, so a server switch/removal isn't silently ignored."
        )
        #expect(
            src.range(
                of:
                    #"func makeAudiobookshelfService\(\)[\s\S]*?invalidateAudiobookshelfServiceCache\(\)"#,
                options: .regularExpression) != nil,
            "makeAudiobookshelfService() must call invalidateAudiobookshelfServiceCache() itself (on a server mismatch or DB-read failure) — otherwise that method is dead code that nothing ever calls."
        )
    }

    /// Final-review Finding #2: `MacPlaybackResumeState` is a SINGLE global resume slot for
    /// the whole app (unlike iOS's per-folder `PlaylistManifestService`). If it still holds a
    /// previously-loaded book's data when a different ABS book loads, pairing that stale
    /// `updatedAt` with the new book's near-zero `currentTime` can look "newer" than genuine
    /// remote progress and force-push a bogus position-0 over it. The fix must only trust the
    /// resume slot when it actually belongs to the book that's loading.
    @Test func reconcileGatesLocalTimestampOnMatchingAudiobookID() throws {
        let src = try MacSource.read("Views/MacPlayerModel+Audiobookshelf.swift")
        #expect(
            src.contains("slot?.audiobookID == audiobookID"),
            "reconcileABSProgressOnLoad() must only trust MacPlaybackResumeState's updatedAt when the resume slot's audiobookID matches the book currently loading — otherwise a stale global slot from a different book can pair the wrong timestamp with this book's playhead."
        )
        #expect(
            src.range(
                of: #"func reconcileABSProgressOnLoad\(\)[\s\S]*?localUpdatedAt[\s\S]*?: nil"#,
                options: .regularExpression) != nil,
            "When the resume slot doesn't match the loading book, localUpdatedAt must fall back to nil (the reconciler's documented 'no local stamp → trust remote' default), not the mismatched slot's timestamp."
        )
    }

    @Test func wiresProgressSyncIntoPlaybackHooks() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("refreshABSSyncIdentity()")
                && src.contains("reconcileABSProgressOnLoad()"),
            "Loading a book must refresh ABS sync identity and reconcile remote progress.")
        #expect(
            src.contains("maybePushABSProgress()"),
            "The periodic time observer must push throttled ABS progress while playing.")
        #expect(
            src.contains("maybePushABSProgress(force: true)"),
            "Pause and stop must force-flush ABS progress immediately.")
    }

    @Test func supportsMultipleSavedServers() throws {
        let src = try MacSource.read("Views/MacAudiobookshelfView.swift")
        #expect(
            src.contains("case addingServer"),
            "Phase must support adding another server without losing the active connection.")
        #expect(
            src.contains("func switchTo(") && src.contains(".setActive("),
            "Switching servers must mark the chosen one active via the shared DAO.")
        #expect(
            src.contains("func removeSavedServer(") && src.contains("ABSTokenStore(serverID:"),
            "Removing a saved server must clear its Keychain tokens.")
        #expect(
            src.contains("savedServers") && src.contains(".all()"),
            "The saved-servers list must be loaded via the shared DAO's all().")
    }
}
