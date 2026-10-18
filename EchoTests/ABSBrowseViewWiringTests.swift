// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import UIKit

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
        #expect(connections.contains("onDismiss: cancelBrowse"))
        #expect(connections.contains("activeBrowseModel?.cancelImport()"))
        #expect(connections.contains("activeBrowseModel?.cancel()"))
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
        let known = ABSImportPresentation.progressLabel(
            ABSImportProgress(
                stage: .downloading, completedUnits: 512, totalUnits: 1024, unit: .bytes))
        let unknown = ABSImportPresentation.progressLabel(
            ABSImportProgress(
                stage: .downloading, completedUnits: 512, totalUnits: nil, unit: .bytes))

        #expect(known.contains("50%"))
        #expect(known.contains(" of "))
        #expect(!unknown.contains("%"))
        #expect(!unknown.contains(" of "))
    }

    @Test func progressCopyClampsPercentageForOverreportedBytes() {
        let progress = ABSImportPresentation.progressLabel(
            ABSImportProgress(
                stage: .downloading, completedUnits: 1536, totalUnits: 1024, unit: .bytes))

        #expect(progress.contains("100%"))
        #expect(!progress.contains("150%"))
    }

    @Test func extractionCopyDistinguishesBytesFromFiles() {
        let bytes = ABSImportPresentation.progressLabel(
            ABSImportProgress(
                stage: .extracting, completedUnits: 512, totalUnits: 1024, unit: .bytes))
        let files = ABSImportPresentation.progressLabel(
            ABSImportProgress(
                stage: .extracting, completedUnits: 1, totalUnits: 2, unit: .files))

        #expect(bytes.contains("50%"))
        #expect(bytes.contains("KB") || bytes.contains("bytes"))
        #expect(files.contains("50%"))
        #expect(files.contains("1 of 2 files"))
    }

    @Test func browseLifecycleOwnsSelectionAndCancelsImportWork() throws {
        let source = try EchoSource.read("Views/ABSBrowseView.swift")

        #expect(source.contains("@State private var selectedItem: ABSLibraryItem?"))
        #expect(source.contains("@State private var importWrapperTask: Task<Void, Never>?"))
        #expect(source.contains(".navigationDestination(isPresented:"))
        #expect(source.contains(".onDisappear { cancelActiveImport() }"))
        #expect(source.contains("UIApplication.shared.beginBackgroundTask("))
        #expect(source.contains("withName: \"abs-import\""))
        #expect(source.contains("Task { @MainActor [weak self] in self?.handleExpiration() }"))
        #expect(source.contains("browseModel.cancelImport()"))
    }

    @Test func progressAccessibilityLeavesCancelSeparateAndCountHasValue() throws {
        let source = try EchoSource.read("Views/ABSBrowseView.swift")

        #expect(source.contains(".accessibilityValue(resultCountAccessibilityValue)"))
        #expect(source.contains("private var progressContent: some View"))
        #expect(
            source.contains(
                "progressContent\n                .accessibilityElement(children: .combine)"))
        #expect(source.contains("Button(role: .destructive, action: cancel)"))
        #expect(source.contains(".disabled(browseModel.isImporting)"))
    }

    @MainActor
    @Test func backgroundExpirationCancelsAndEndsExactlyOnce() {
        var cancellationCount = 0
        var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
        let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
        let backgroundTask = ABSImportBackgroundTask(
            testIdentifier: identifier,
            endHandler: { endedIdentifiers.append($0) },
            expirationHandler: { cancellationCount += 1 })

        backgroundTask.handleExpiration()
        backgroundTask.handleExpiration()
        backgroundTask.end()

        #expect(cancellationCount == 1)
        #expect(endedIdentifiers == [identifier])
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
