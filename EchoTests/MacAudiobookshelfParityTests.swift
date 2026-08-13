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

    @Test func browseUsesSharedStateAndRetainsSuccess() throws {
        let host = try MacSource.read("Views/MacAudiobookshelfView.swift")
        let browse = try MacSource.read("Views/MacAudiobookshelfBrowseView.swift")
        #expect(
            host.contains("ABSBrowseModel(")
                && host.contains("var browseModel: ABSBrowseModel?"),
            "macOS must construct and retain the shared browse model after connecting.")
        #expect(
            browse.contains("Open in Echo")
                && browse.contains("Clear Filters")
                && browse.contains("Not Added to Echo"),
            "The native Mac browser must expose retained success and matching filters.")
        #expect(
            browse.contains("onPlay(book.folderURL)"),
            "Only the explicit Open in Echo action should hand the imported folder to playback.")
        #expect(
            !browse.contains("if await model.addToLibrary(item) { dismiss() }"),
            "A successful import must not dismiss the Audiobookshelf browser.")
    }

    @Test func browseExposesMatchingOrganizationAndPagingControls() throws {
        let browse = try MacSource.read("Views/MacAudiobookshelfBrowseView.swift")

        #expect(browse.contains("Library"))
        #expect(browse.contains("Sort"))
        #expect(browse.contains("Filters"))
        #expect(browse.contains("Search Audiobookshelf"))
        #expect(browse.contains("loadNextPageIfNeeded"))
        #expect(browse.contains("refresh()"))
        #expect(browse.contains("Result count"))
    }

    @Test func browseRetainsIndependentSelectionAndImportOutcomes() throws {
        let browse = try MacSource.read("Views/MacAudiobookshelfBrowseView.swift")

        #expect(browse.contains("@State private var selectedItem: ABSLibraryItem?"))
        #expect(browse.contains("browseModel.importState(for:"))
        #expect(browse.contains("MacABSImportPresentation.progressLabel(progress)"))
        #expect(browse.contains("Elapsed"))
        #expect(browse.contains("Cancel Import"))
        #expect(browse.contains("Retry"))
        #expect(browse.contains("Added to Echo"))
        #expect(browse.contains(".disabled(browseModel.isImporting)"))
    }

    @Test func browseLifecycleCancelsOwnedWork() throws {
        let host = try MacSource.read("Views/MacAudiobookshelfView.swift")
        let browse = try MacSource.read("Views/MacAudiobookshelfBrowseView.swift")

        #expect(host.contains("browseModel?.cancelImport()"))
        #expect(host.contains("browseModel?.cancel()"))
        #expect(browse.contains(".onDisappear { cancelOwnedWork() }"))
        #expect(browse.contains("browseModel.cancelImport()"))
        #expect(browse.contains("browseModel.cancel()"))
    }

    @Test func switchingConnectionsReplacesBrowseOwnership() throws {
        let host = try MacSource.read("Views/MacAudiobookshelfView.swift")

        #expect(
            host.range(
                of: #"func installBrowseModel\([\s\S]*?browseModel = ABSBrowseModel\("#,
                options: .regularExpression) != nil)
        #expect(
            host.range(
                of: #"func switchTo\([\s\S]*?installBrowseModel\("#,
                options: .regularExpression) != nil)
        #expect(
            host.range(
                of: #"func removeSavedServer\([\s\S]*?browseModel = nil"#,
                options: .regularExpression) != nil)
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

    /// Found via live device testing: with exactly one saved server, `savedServers.count`
    /// can never reach 2 without going through "Switch Server…" first — so gating that
    /// button on `count > 1` made it permanently unreachable the moment you have only one
    /// server connected. There must be no such count-based gate on the entry point that
    /// lets you add a second server.
    @Test func addServerEntryPointIsNotGatedOnAlreadyHavingTwoServers() throws {
        let src = try MacSource.read("Views/MacAudiobookshelfView.swift")
        #expect(
            !src.contains("model.savedServers.count > 1"),
            "The \"Switch Server…\" button must not require savedServers.count > 1 — that count can only ever reach 2 by going through this same button, so gating on it is an unreachable dead end with exactly one saved server."
        )
        #expect(
            src.range(
                of:
                    #"model\.phase == \.connected, let server = model\.server \{[\s\S]*?Switch Server…"#,
                options: .regularExpression) != nil,
            "\"Switch Server…\" must still be shown whenever a server is connected, just no longer gated by count."
        )
    }

    /// Connecting manually must replace the server-scoped shared browser before loading.
    /// Reusing the prior model would retain that server's library/filter IDs and can query
    /// them against the new server, reproducing the observed cross-server HTTP 404.
    @Test func attemptConnectInstallsFreshBrowseModelBeforeLoadingNewServer() throws {
        let src = try MacSource.read("Views/MacAudiobookshelfView.swift")
        #expect(
            src.range(
                of:
                    #"func attemptConnect\([\s\S]*?installBrowseModel\([\s\S]*?await browseModel\?\.load\(\)"#,
                options: .regularExpression) != nil,
            "attemptConnect() must install and load a fresh ABSBrowseModel for the newly-connected server, so prior server query state cannot leak across the switch."
        )
    }
}
