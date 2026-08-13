// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ABSBrowseViewWiringTests {
    @Test func iOSUsesSharedModelAndRetainsImportOutcomes() throws {
        let source = try EchoSource.read("Views/ABSBrowseView.swift")

        #expect(source.contains("let browseModel: ABSBrowseModel"))
        #expect(source.contains("Open in Echo"))
        #expect(source.contains("browseModel.importState(for:"))
        #expect(!source.contains("onImported: { dismiss() }"))
        #expect(!source.contains("addFromAudiobookshelf"))
    }

    @Test func connectionsInjectsBrowseModelAndOnlyOpenDismisses() throws {
        let player = try EchoSource.read("ViewModels/PlayerModel+Audiobookshelf.swift")
        let connections = try EchoSource.read("Views/ABSConnectionsSettingsView.swift")

        #expect(player.contains("func makeABSBrowseModel() -> ABSBrowseModel?"))
        #expect(player.contains("func openAudiobookshelfBook(_ book: ABSImportedBook)"))
        #expect(connections.contains("model.makeABSBrowseModel()"))
        #expect(connections.contains("model.openAudiobookshelfBook(book)"))
        #expect(connections.contains("browseDestination = nil"))
    }

    @Test func browseExposesOrganizationPagingAndRefreshControls() throws {
        let source = try EchoSource.read("Views/ABSBrowseView.swift")

        #expect(source.contains("Sort"))
        #expect(source.contains("Filters"))
        #expect(source.contains("Clear Filters"))
        #expect(source.contains("Not Added to Echo"))
        #expect(source.contains(".refreshable"))
        #expect(source.contains("loadNextPageIfNeeded"))
        #expect(source.contains("Added"))
    }

    @Test func progressCopyDistinguishesKnownAndUnknownTotals() {
        let known = ABSImportPresentation.progressLabel(completed: 512, total: 1024)
        let unknown = ABSImportPresentation.progressLabel(completed: 512, total: nil)

        #expect(known.contains("50%"))
        #expect(known.contains(" of "))
        #expect(!unknown.contains("%"))
        #expect(!unknown.contains(" of "))
    }

    @Test func progressCopyClampsPercentageForOverreportedBytes() {
        let progress = ABSImportPresentation.progressLabel(completed: 1536, total: 1024)

        #expect(progress.contains("100%"))
        #expect(!progress.contains("150%"))
    }
}

private enum EchoSource {
    static func read(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
                .appending(path: "EchoCore/\(relativePath)")
            if let source = try? String(contentsOf: candidate, encoding: .utf8) {
                return source
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
