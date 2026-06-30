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
}
