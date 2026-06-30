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
}
