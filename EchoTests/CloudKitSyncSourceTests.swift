// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct CloudKitSyncSourceTests {
    @Test func downloadFetchesDeterministicRecordInsteadOfMetadataQuery() throws {
        let source = try Self.source("EchoCore/Services/CloudKitSyncService.swift")

        #expect(source.contains("publicDatabase.record(for: recordID)"))
        #expect(source.contains("AlignmentSidecar.portableSuffix(of: anchor.epubBlockID)"))
        #expect(source.contains("let validAnchors = Self.semanticallyValidRemoteAnchors"))
        #expect(!source.contains("records(matching:"))
        #expect(!source.contains("CKQuery(recordType: Self.sharedAlignmentRecordType"))
    }

    @Test func uploadConflictSanitizesRemoteAnchorsBeforeMerge() throws {
        let source = try Self.source("EchoCore/Services/CloudKitSyncService.swift")

        #expect(source.contains("let sanitizedRemoteAnchors = Self.semanticallyValidRemoteAnchors"))
        #expect(source.contains("let merged = Self.mergeAnchors(local: anchors, remote: sanitizedRemoteAnchors)"))
    }

    @Test func manualShareUsesPersistedAnchorLookupMetadata() throws {
        let source = try Self.source("EchoCore/Views/BookSettingsView.swift")

        #expect(source.contains("AudiobookDAO(db: db).get(audiobookID)"))
        #expect(source.contains("EPUBAutoImportScanner.anchorLookupMetadata"))
        #expect(source.contains("(record?.duration).flatMap"))
    }

    @Test func bookSettingsRefreshesEchoDeckBuilderExportAfterDocumentImport() throws {
        let source = try Self.source("EchoCore/Views/BookSettingsView.swift")

        #expect(source.contains("Make Flashcards in EchoDeckBuilder"))
        #expect(source.contains("EchoDeckBuilderRefreshKey"))
        #expect(source.contains("sourceDocumentURL: model.state.sourceDocumentURL"))
        #expect(source.contains("documentIngestionTrigger: model.state.documentIngestionTrigger"))
    }

    @Test func documentImportSkipsCloudKitWhenContainerIsNotEntitled() throws {
        let finalizerSource = try Self.source("EchoCore/Services/DocumentImportFinalizer.swift")
        let syncSource = try Self.source("EchoCore/Services/CloudKitSyncService.swift")

        #expect(finalizerSource.contains("CloudKitSyncService.canAccessConfiguredContainer()"))
        #expect(
            finalizerSource.contains(
                "Skipped CloudKit anchor lookup because the app is not entitled"))
        #expect(syncSource.contains("#if targetEnvironment(simulator)"))
        #expect(syncSource.contains("#elseif os(iOS)"))
        #expect(syncSource.contains("com.apple.developer.icloud-container-identifiers"))
        #expect(syncSource.contains("com.apple.developer.icloud-services"))
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
