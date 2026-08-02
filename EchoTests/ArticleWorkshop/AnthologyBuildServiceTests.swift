// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite(.serialized)
struct AnthologyBuildServiceTests {
    @Test func successfulBuildAtomicallyPublishesAndRecordsReady() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }

        let record = try await fixture.service().build(
            anthologyID: fixture.anthologyID.uuidString)

        #expect(record.status == "succeeded")
        #expect(record.revision == fixture.manifest.revision)
        #expect(record.epubPath == fixture.finalURL.path)
        #expect(record.audiobookID == fixture.audiobookID)
        #expect(try Data(contentsOf: fixture.finalURL) == fixture.epubData)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString) == record)
        let audiobook = try #require(try fixture.audiobookDAO.get(fixture.audiobookID))
        #expect(audiobook.title == fixture.manifest.title)
        #expect(audiobook.author == fixture.manifest.creator)
        #expect(audiobook.textOrigin == "epub")
        #expect(audiobook.id == fixture.audiobookID)
        #expect(try fixture.taskTemporaryFiles().isEmpty)
    }

    @Test(
        "Failures preserve the prior coherent edition",
        arguments: AnthologyBuildFailurePoint.allCases)
    func everyFailurePointPreservesPriorEdition(
        point: AnthologyBuildFailurePoint
    ) async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let prior = try fixture.seedPriorEdition()

        if point.reportsPublicationRecoveryFailure {
            await #expect(throws: AnthologyBuildService.Error.publicationRecoveryFailed) {
                try await fixture.service(failure: point).build(
                    anthologyID: fixture.anthologyID.uuidString)
            }
        } else {
            await #expect(throws: AnthologyBuildService.Error.self) {
                try await fixture.service(failure: point).build(
                    anthologyID: fixture.anthologyID.uuidString)
            }
        }

        #expect(try Data(contentsOf: fixture.finalURL) == prior.epubData)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString) == prior.build)
        try fixture.expectAudiobookMatches(prior.audiobook)
        let attempts = try fixture.builds()
        #expect(attempts.filter { $0.status == "failed" }.count == 1)
        #expect(attempts.filter { $0.status == "succeeded" } == [prior.build])
        if point.reportsPublicationRecoveryFailure {
            #expect(attempts.last?.errorCode == "publication_recovery_failed")
        }
        #expect(try fixture.taskTemporaryFiles().isEmpty)
    }

    @Test func failedRetryDoesNotConsumeRevision() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(failure: .builder).build(
                anthologyID: fixture.anthologyID.uuidString)
        }
        let successful = try await fixture.service().build(
            anthologyID: fixture.anthologyID.uuidString)

        #expect(successful.revision == fixture.manifest.revision)
        #expect(try fixture.builds().map(\.revision) == [1, 1])
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString)?.revision == 1)
    }

    @Test func firstPublicationSyncFailureRemovesCandidateAndRecordsFailure() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(
                publicationFaults: [.afterFirstPublishBeforeSync]
            ).build(anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.finalURL.path) == false)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString) == nil)
        #expect(try fixture.audiobookDAO.get(fixture.audiobookID) == nil)
        #expect(try fixture.taskTemporaryFiles().isEmpty)
        let attempts = try fixture.builds()
        #expect(attempts.count == 1)
        #expect(attempts[0].status == "failed")
    }

    @Test func firstPublicationRecoverySyncFailureReportsDistinctError() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }

        await #expect(throws: AnthologyBuildService.Error.publicationRecoveryFailed) {
            try await fixture.service(
                publicationFaults: [
                    .afterFirstPublishBeforeSync,
                    .beforeFirstRecoverySync,
                ]
            ).build(anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.finalURL.path) == false)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString) == nil)
        #expect(try fixture.audiobookDAO.get(fixture.audiobookID) == nil)
        #expect(try fixture.taskTemporaryFiles().isEmpty)
        let attempts = try fixture.builds()
        #expect(attempts.count == 1)
        let attempt = try #require(attempts.first)
        #expect(attempt.status == "failed")
        #expect(attempt.errorCode == "publication_recovery_failed")
    }

    @Test func rebuildKeepsStableAudiobookIdentityAndUpdatesMetadata() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let first = try await fixture.service().build(
            anthologyID: fixture.anthologyID.uuidString)
        let updated = fixture.manifest(
            revision: 2,
            title: "A Revised Small Book",
            creator: "A Different Editor")

        let second = try await fixture.service(manifest: updated).build(
            anthologyID: fixture.anthologyID.uuidString)

        #expect(first.audiobookID == second.audiobookID)
        #expect(second.audiobookID == fixture.audiobookID)
        let audiobook = try #require(try fixture.audiobookDAO.get(fixture.audiobookID))
        #expect(audiobook.title == updated.title)
        #expect(audiobook.author == updated.creator)
        #expect(try fixture.audiobookDAO.all().count == 1)
    }

    @Test(
        "Build result and import receipts must agree exactly",
        arguments: AnthologyReceiptMismatch.allCases)
    func receiptDigestAndIdentityMismatchFailsClosed(
        mismatch: AnthologyReceiptMismatch
    ) async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let prior = try fixture.seedPriorEdition()

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(mismatch: mismatch).build(
                anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(try Data(contentsOf: fixture.finalURL) == prior.epubData)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString) == prior.build)
        try fixture.expectAudiobookMatches(prior.audiobook)
    }

    @Test func stagedSymlinkIsRejectedWithoutTouchingExternalFile() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let outside = fixture.root.appending(path: "outside.epub")
        let outsideData = Data("outside sentinel".utf8)
        try outsideData.write(to: outside)

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(stagedSymlinkTarget: outside).build(
                anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(try Data(contentsOf: outside) == outsideData)
        #expect(FileManager.default.fileExists(atPath: fixture.finalURL.path) == false)
    }

    @Test func symlinkedFinalIsRejectedWithoutFollowingOrDeletingIt() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let outside = fixture.root.appending(path: "outside.epub")
        let outsideData = Data("outside sentinel".utf8)
        try outsideData.write(to: outside)
        try fixture.createEditionDirectory()
        try FileManager.default.createSymbolicLink(
            at: fixture.finalURL,
            withDestinationURL: outside)

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service().build(anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(try Data(contentsOf: outside) == outsideData)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.finalURL.path) == outside.path)
    }

    @Test func substitutedResultPathIsRejectedWithoutExternalWrites() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let outside = fixture.root.appending(path: "outside.epub")
        let outsideData = Data("outside sentinel".utf8)
        try outsideData.write(to: outside)

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(substitutedResultURL: outside).build(
                anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(try Data(contentsOf: outside) == outsideData)
        #expect(FileManager.default.fileExists(atPath: fixture.finalURL.path) == false)
    }

    @Test func missingImageMappingRecordsFailureAndPreservesPriorEdition() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let prior = try fixture.seedPriorEdition()
        let imageManifest = fixture.manifestWithImageBlock()

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(
                manifest: imageManifest,
                useRealBuilder: true
            ).build(anthologyID: fixture.anthologyID.uuidString)
        }

        #expect(try Data(contentsOf: fixture.finalURL) == prior.epubData)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: fixture.anthologyID.uuidString) == prior.build)
        let failure = try #require(fixture.builds().last)
        #expect(failure.status == "failed")
        #expect(failure.errorCode == "missing_image_asset_mapping")
        #expect(failure.revision == imageManifest.revision)
    }

    @Test func dependencySurfaceUsesExplicitLocalOnlyImportPolicy() throws {
        let source = try String(
            contentsOf: sourceURL("EchoCore/Services/ArticleWorkshop/AnthologyBuildService.swift"),
            encoding: .utf8)

        #expect(source.contains("URLSession") == false)
        #expect(source.contains("data(from:") == false)
        #expect(source.contains("downloadTask") == false)
        #expect(source.contains("http://") == false)
        #expect(source.contains("https://") == false)
        #expect(
            source.components(separatedBy: "networkPolicy: .localOnly").count - 1
                == 2)
    }

    @Test func sameAnthologyConcurrentBuildIsRejectedBeforeSecondBuilderInvocation() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let gate = AnthologyBuildPause()
        let invocations = LockedInvocationCounter()
        let service = fixture.service(
            importerPause: gate,
            builderInvocations: invocations)
        let first = Task {
            try await service.build(anthologyID: fixture.anthologyID.uuidString)
        }
        await gate.waitUntilPaused()

        do {
            _ = try await service.build(anthologyID: fixture.anthologyID.uuidString)
            Issue.record("A second same-anthology build should be rejected.")
        } catch let error as AnthologyBuildService.Error {
            #expect(error == .buildAlreadyInProgress)
        }
        #expect(invocations.value == 1)

        await gate.release()
        _ = try await first.value
    }

    @Test func rebuildBackupIsOwnedDirectChildWithNonEPUBExtension() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        _ = try fixture.seedPriorEdition()
        let gate = AnthologyBuildPause()
        let updated = fixture.manifest(
            revision: 2,
            title: "A Revised Small Book",
            creator: "A Different Editor")
        let service = fixture.service(
            manifest: updated,
            importerPause: gate)
        let build = Task {
            try await service.build(anthologyID: fixture.anthologyID.uuidString)
        }
        await gate.waitUntilPaused()

        let residue = try fixture.taskTemporaryFiles()
        let rollback = try #require(
            residue.first { $0.pathExtension == "rollback" })
        #expect(residue.count == 1)
        #expect(
            rollback.deletingLastPathComponent().standardizedFileURL
                == fixture.editionDirectory.standardizedFileURL)
        #expect(rollback.lastPathComponent.hasPrefix(".book-"))
        #expect(rollback.lastPathComponent.hasSuffix(".rollback"))
        #expect(rollback.pathExtension != "epub")

        await gate.release()
        _ = try await build.value
        #expect(try fixture.taskTemporaryFiles().isEmpty)
    }

    @Test func persistedSnapshotRequiresCoherentManagedOutputAndShowsLatestFailure() async throws {
        let fixture = try AnthologyBuildServiceFixture()
        defer { fixture.removeFiles() }
        let service = fixture.service()

        let empty = try await service.snapshot(
            anthologyID: fixture.anthologyID.uuidString,
            changesAvailable: false)
        #expect(empty.status == .notBuilt)
        #expect(empty.finalURL == nil)
        #expect(empty.audiobookID == nil)

        let prior = try fixture.seedPriorEdition()
        let ready = try await service.snapshot(
            anthologyID: fixture.anthologyID.uuidString,
            changesAvailable: false)
        #expect(ready.status == .ready(revision: prior.build.revision))
        #expect(ready.finalURL == fixture.finalURL)
        #expect(ready.audiobookID == fixture.audiobookID)

        let changed = try await service.snapshot(
            anthologyID: fixture.anthologyID.uuidString,
            changesAvailable: true)
        #expect(
            changed.status
                == .changesAvailable(
                    builtRevision: prior.build.revision))

        await #expect(throws: AnthologyBuildService.Error.self) {
            try await fixture.service(failure: .builder).build(
                anthologyID: fixture.anthologyID.uuidString)
        }
        let failed = try await service.snapshot(
            anthologyID: fixture.anthologyID.uuidString,
            changesAvailable: true)
        #expect(failed.status == .failed(previousRevision: prior.build.revision))
        #expect(failed.finalURL == fixture.finalURL)

        try Data("tampered".utf8).write(to: fixture.finalURL, options: .atomic)
        let tampered = try await service.snapshot(
            anthologyID: fixture.anthologyID.uuidString,
            changesAvailable: false)
        #expect(tampered.status == .failed(previousRevision: nil))
        #expect(tampered.finalURL == nil)
        #expect(tampered.audiobookID == nil)
    }

    @Test func libraryWiringUsesDatabaseBackedBuilderAndStableEditionOpenTarget() throws {
        let librarySource = try String(
            contentsOf: sourceURL("EchoCore/Views/Library/LibraryView.swift"),
            encoding: .utf8)
        let listSource = try String(
            contentsOf: sourceURL(
                "EchoCore/Views/ArticleWorkshop/AnthologyListView.swift"),
            encoding: .utf8)
        let detailSource = try String(
            contentsOf: sourceURL(
                "EchoCore/Views/ArticleWorkshop/AnthologyDetailView.swift"),
            encoding: .utf8)

        #expect(librarySource.contains("AnthologyBuildService("))
        #expect(librarySource.contains("databaseService: db"))
        #expect(librarySource.contains("buildService: anthologyBuildService"))
        #expect(librarySource.contains("openBook: openBook"))
        #expect(
            librarySource.contains(
                """
                case .books:
                                    vm.reload()
                """))
        #expect(listSource.contains("buildService: buildService"))
        #expect(listSource.contains("openBook: openBook"))
        #expect(detailSource.contains("LibraryOpenTarget("))
        #expect(detailSource.contains("finalURL.deletingLastPathComponent()"))
        #expect(detailSource.contains("ViewThatFits(in: .horizontal)"))
        #expect(detailSource.contains("acceptedBuildResult("))
    }

    @Test func epubPresentationKeepsOutputActionsSeparateFromBuildState() {
        let notBuilt = AnthologyEPUBPresentation(
            status: .notBuilt,
            hasChapters: true,
            isSaving: false,
            hasValidatedOutput: false)
        #expect(notBuilt.primaryActionTitle == "Build EPUB")
        #expect(notBuilt.canBuild)
        #expect(notBuilt.canOpen == false)
        #expect(notBuilt.canShare == false)
        #expect(notBuilt.accessibilityLabel == "EPUB status")
        #expect(notBuilt.accessibilityValue == "Not built")

        let building = AnthologyEPUBPresentation(
            status: .building,
            hasChapters: true,
            isSaving: false,
            hasValidatedOutput: true)
        #expect(building.primaryActionTitle == nil)
        #expect(building.showsProgress)
        #expect(building.canOpen == false)
        #expect(building.canShare == false)

        let changes = AnthologyEPUBPresentation(
            status: .changesAvailable(builtRevision: 3),
            hasChapters: true,
            isSaving: false,
            hasValidatedOutput: true)
        #expect(changes.primaryActionTitle == "Rebuild EPUB")
        #expect(changes.canBuild)
        #expect(changes.canOpen)
        #expect(changes.canShare)
        #expect(changes.accessibilityValue == "Changes available after revision 3")

        let failedWithoutPrior = AnthologyEPUBPresentation(
            status: .failed(previousRevision: nil),
            hasChapters: true,
            isSaving: false,
            hasValidatedOutput: false)
        #expect(failedWithoutPrior.primaryActionTitle == "Build EPUB")
        #expect(failedWithoutPrior.canOpen == false)

        let failedWithPrior = AnthologyEPUBPresentation(
            status: .failed(previousRevision: 4),
            hasChapters: true,
            isSaving: false,
            hasValidatedOutput: true)
        #expect(failedWithPrior.primaryActionTitle == "Rebuild EPUB")
        #expect(failedWithPrior.canOpen)
        #expect(failedWithPrior.canShare)
        #expect(failedWithPrior.accessibilityValue.contains("Revision 4 remains available"))

        let saving = AnthologyEPUBPresentation(
            status: .ready(revision: 4),
            hasChapters: true,
            isSaving: true,
            hasValidatedOutput: true)
        #expect(saving.canBuild == false)
        #expect(saving.canOpen)

        let pendingSaveFailure = AnthologyEPUBPresentation(
            status: .changesAvailable(builtRevision: 4),
            hasChapters: true,
            isSaving: false,
            hasValidatedOutput: true,
            hasPendingSaveFailure: true)
        #expect(pendingSaveFailure.primaryActionTitle == "Rebuild EPUB")
        #expect(pendingSaveFailure.canBuild == false)
        #expect(pendingSaveFailure.canOpen)
    }

    @Test func staleDetailLoadAndBuildGenerationsCannotPublish() {
        var generations = AnthologyDetailGeneration()
        let oldLoad = generations.beginLoad()
        let currentLoad = generations.beginLoad()
        #expect(generations.acceptsLoad(oldLoad) == false)
        #expect(generations.acceptsLoad(currentLoad))
        let finishedOldLoad = generations.finishLoad(oldLoad)
        let finishedCurrentLoad = generations.finishLoad(currentLoad)
        #expect(finishedOldLoad == false)
        #expect(finishedCurrentLoad)

        let oldBuild = generations.beginBuild()
        let currentBuild = generations.beginBuild()
        #expect(generations.acceptsBuild(oldBuild) == false)
        #expect(generations.acceptsBuild(currentBuild))
        let finishedOldBuild = generations.finishBuild(oldBuild)
        let finishedCurrentBuild = generations.finishBuild(currentBuild)
        #expect(finishedOldBuild == false)
        #expect(finishedCurrentBuild)

        let supersededLoad = generations.beginLoad()
        let newerBuild = generations.beginBuild()
        #expect(generations.acceptsLoad(supersededLoad) == false)
        #expect(generations.acceptsBuild(newerBuild))

        let supersededBuild = generations.beginBuild()
        let newerLoad = generations.beginLoad()
        #expect(generations.acceptsBuild(supersededBuild) == false)
        #expect(generations.acceptsLoad(newerLoad))
        #expect(
            generations.acceptedBuildResult(
                "stale failure snapshot",
                generation: supersededBuild) == nil)

        let newestBuild = generations.beginBuild()
        #expect(
            generations.acceptedBuildResult(
                "current failure snapshot",
                generation: newestBuild) == "current failure snapshot")
    }

    private func sourceURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
    }
}

enum AnthologyBuildFailurePoint: String, CaseIterable, Sendable {
    case builder
    case preflight
    case libraryLoad
    case publicationSync
    case publicationSyncRecoverySwap
    case publicationRecoverySync
    case publicationFallbackRecoverySync
    case librarySave
    case importer
    case finalDigest
    case successfulReceipt

    var reportsPublicationRecoveryFailure: Bool {
        switch self {
        case .publicationRecoverySync, .publicationFallbackRecoverySync:
            return true
        default:
            return false
        }
    }
}

enum AnthologyReceiptMismatch: String, CaseIterable, Sendable {
    case temporaryURL
    case manifestSHA256
    case epubSHA256
    case identifier
    case revision
    case importedAudiobookID
}

@MainActor
private struct AnthologyBuildServiceFixture {
    struct PriorEdition {
        let epubData: Data
        let build: AnthologyBuildRecord
        let audiobook: AudiobookRecord
    }

    let root: URL
    let workshopRoot: URL
    let database: DatabaseService
    let anthologyDAO: AnthologyDAO
    let audiobookDAO: AudiobookDAO
    let anthologyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let manifest: AnthologyBuildManifest
    let epubData = Data("validated epub bytes".utf8)

    var editionDirectory: URL {
        workshopRoot
            .appending(path: "Editions", directoryHint: .isDirectory)
            .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
    }

    var finalURL: URL {
        editionDirectory.appending(path: "book.epub")
    }

    var audiobookID: String {
        editionDirectory.standardizedFileURL.absoluteString
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "AnthologyBuildServiceTests-\(UUID().uuidString)")
        workshopRoot = root.appending(path: "ArticleWorkshop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workshopRoot, withIntermediateDirectories: true)
        database = try DatabaseService(inMemory: ())
        anthologyDAO = AnthologyDAO(db: database.writer)
        audiobookDAO = AudiobookDAO(db: database.writer)
        manifest = Self.makeManifest(anthologyID: anthologyID)
        try anthologyDAO.save(
            AnthologyRecord(
                id: anthologyID.uuidString,
                title: manifest.title,
                subtitle: manifest.subtitle,
                creator: manifest.creator,
                coverPath: nil,
                nextStableSlot: 1,
                latestBuildRevision: 0,
                createdAt: "2026-07-29T12:00:00Z",
                modifiedAt: "2026-07-29T12:00:00Z"))
    }

    func service(
        manifest requestedManifest: AnthologyBuildManifest? = nil,
        failure: AnthologyBuildFailurePoint? = nil,
        mismatch: AnthologyReceiptMismatch? = nil,
        stagedSymlinkTarget: URL? = nil,
        substitutedResultURL: URL? = nil,
        useRealBuilder: Bool = false,
        importerPause: AnthologyBuildPause? = nil,
        builderInvocations: LockedInvocationCounter? = nil,
        publicationFaults: Set<AnthologyPublicationFaultPoint> = []
    ) -> AnthologyBuildService {
        let manifest = requestedManifest ?? manifest
        let epubData = epubData
        let database = database
        let builder = AnthologyEPUBBuilder(workshopRoot: workshopRoot)
        let audiobookID = audiobookID
        let writer = database.writer
        var publicationFaults = publicationFaults
        switch failure {
        case .publicationSync:
            publicationFaults.insert(.afterReplacementBeforeSync)
        case .publicationSyncRecoverySwap:
            publicationFaults.insert(.afterReplacementBeforeSync)
            publicationFaults.insert(.beforeReplacementRecoverySwap)
        case .publicationRecoverySync:
            publicationFaults.insert(.afterReplacementBeforeSync)
            publicationFaults.insert(.beforeReplacementRecoverySync)
        case .publicationFallbackRecoverySync:
            publicationFaults.insert(.afterReplacementBeforeSync)
            publicationFaults.insert(.beforeReplacementRecoverySwap)
            publicationFaults.insert(.beforeReplacementRecoverySync)
        default:
            break
        }
        let injectedPublicationFaults = publicationFaults
        return AnthologyBuildService(
            workshopRoot: workshopRoot,
            databaseService: database,
            dependencies: .init(
                freezeManifest: { _ in manifest },
                buildEPUB: { manifest, destination in
                    let invocation = builderInvocations?.increment() ?? 1
                    if invocation > 1 {
                        throw FixtureError.secondBuilderInvocation
                    }
                    if failure == .builder {
                        throw FixtureError.injected
                    }
                    if useRealBuilder {
                        return try builder.build(manifest: manifest, to: destination)
                    }
                    if let stagedSymlinkTarget {
                        try FileManager.default.createSymbolicLink(
                            at: destination,
                            withDestinationURL: stagedSymlinkTarget)
                    } else {
                        try epubData.write(to: destination, options: .withoutOverwriting)
                    }
                    return AnthologyEPUBBuildResult(
                        temporaryURL: substitutedResultURL
                            ?? (mismatch == .temporaryURL
                                ? destination.deletingLastPathComponent()
                                    .appending(path: "other.epub")
                                : destination),
                        epubSHA256: mismatch == .epubSHA256
                            ? String(repeating: "0", count: 64)
                            : Self.sha256(epubData),
                        manifestSHA256: mismatch == .manifestSHA256
                            ? String(repeating: "1", count: 64)
                            : Self.manifestSHA256(manifest),
                        identifier: mismatch == .identifier
                            ? "urn:uuid:00000000-0000-0000-0000-000000000000"
                            : manifest.epubIdentifier,
                        revision: mismatch == .revision
                            ? manifest.revision + 1
                            : manifest.revision)
                },
                preflight: { _, _ in
                    if failure == .preflight {
                        throw FixtureError.injected
                    }
                },
                importEPUB: { finalURL, _, requestedID in
                    if let importerPause {
                        await importerPause.pause()
                    }
                    if failure == .importer {
                        throw FixtureError.injected
                    }
                    if failure == .finalDigest {
                        try Data("post-import mutation".utf8).write(
                            to: finalURL,
                            options: .atomic)
                    }
                    return AnthologyLibraryImportReceipt(
                        audiobookID: mismatch == .importedAudiobookID
                            ? "\(requestedID)-substituted"
                            : requestedID)
                },
                saveBuild: { build in
                    if failure == .successfulReceipt, build.status == "succeeded" {
                        throw FixtureError.injected
                    }
                    try AnthologyDAO(db: writer).saveBuild(build)
                },
                loadAudiobook: { id in
                    if failure == .libraryLoad {
                        throw FixtureError.injected
                    }
                    return try writer.read { db in
                        try AudiobookRecord.fetchOne(db, key: id)
                    }
                },
                saveAudiobook: { record in
                    if failure == .librarySave {
                        throw FixtureError.injected
                    }
                    var copy = record
                    try writer.write { db in
                        try copy.save(db)
                    }
                },
                deleteAudiobook: { id in
                    _ = try writer.write { db in
                        try AudiobookRecord.deleteOne(db, key: id)
                    }
                },
                restoreImport: { _, _, restoredID in
                    guard restoredID == audiobookID else {
                        throw FixtureError.injected
                    }
                },
                publicationFaultInjector: { point in
                    if injectedPublicationFaults.contains(point) {
                        throw FixtureError.injected
                    }
                }),
            now: { Date(timeIntervalSince1970: 1_785_585_600) },
            makeID: UUID.init)
    }

    func seedPriorEdition() throws -> PriorEdition {
        try createEditionDirectory()
        let priorData = Data("prior validated epub bytes".utf8)
        try priorData.write(to: finalURL)
        let build = AnthologyBuildRecord(
            id: "prior-success",
            anthologyID: anthologyID.uuidString,
            revision: manifest.revision,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: Self.manifestJSON(manifest),
            manifestSHA256: Self.manifestSHA256(manifest),
            epubPath: finalURL.path,
            epubSHA256: Self.sha256(priorData),
            audiobookID: audiobookID,
            status: "succeeded",
            errorCode: nil,
            createdAt: "2026-07-29T11:00:00Z")
        try anthologyDAO.saveBuild(build)
        let audiobook = AudiobookRecord(
            id: audiobookID,
            title: "Prior Edition",
            author: "Prior Editor",
            duration: 42,
            fileCount: 1,
            addedAt: "2026-07-29T11:00:00Z",
            coverArtPath: "/prior/cover.jpg",
            textOrigin: "epub")
        try audiobookDAO.save(audiobook)
        return PriorEdition(epubData: priorData, build: build, audiobook: audiobook)
    }

    func createEditionDirectory() throws {
        try FileManager.default.createDirectory(
            at: editionDirectory,
            withIntermediateDirectories: true)
    }

    func builds() throws -> [AnthologyBuildRecord] {
        try database.writer.read { db in
            try AnthologyBuildRecord
                .order(Column("created_at"), Column("id"))
                .fetchAll(db)
        }
    }

    func taskTemporaryFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: editionDirectory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: editionDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(".book-") }
    }

    func manifest(
        revision: Int,
        title: String,
        creator: String
    ) -> AnthologyBuildManifest {
        AnthologyBuildManifest(
            schemaVersion: manifest.schemaVersion,
            anthologyID: manifest.anthologyID,
            revision: revision,
            epubIdentifier: manifest.epubIdentifier,
            title: title,
            subtitle: manifest.subtitle,
            creator: creator,
            language: manifest.language,
            coverPath: manifest.coverPath,
            modifiedAt: manifest.modifiedAt,
            chapters: manifest.chapters)
    }

    func manifestWithImageBlock() -> AnthologyBuildManifest {
        var chapters = manifest.chapters
        let image = ArticleBlock(
            id: "article-image",
            stableOrdinal: 1,
            kind: .image,
            text: "",
            sourceURL: nil,
            imageCandidateURL: URL(string: "https://example.test/image.jpg"),
            caption: "An image",
            codeLanguage: nil)
        let prior = chapters[0]
        let blocks = prior.blocks + [image]
        chapters[0] = AnthologyChapterManifest(
            entryID: prior.entryID,
            captureID: prior.captureID,
            articleRevisionID: prior.articleRevisionID,
            stableSlot: prior.stableSlot,
            order: prior.order,
            title: prior.title,
            author: prior.author,
            siteName: prior.siteName,
            sourceURL: prior.sourceURL,
            capturedAt: prior.capturedAt,
            voiceID: prior.voiceID,
            blocks: blocks,
            readableContentSHA256: ArticleWorkshopDigest.readableContent(
                blocks: blocks))
        return AnthologyBuildManifest(
            schemaVersion: manifest.schemaVersion,
            anthologyID: manifest.anthologyID,
            revision: manifest.revision,
            epubIdentifier: manifest.epubIdentifier,
            title: manifest.title,
            subtitle: manifest.subtitle,
            creator: manifest.creator,
            language: manifest.language,
            coverPath: manifest.coverPath,
            modifiedAt: manifest.modifiedAt,
            chapters: chapters)
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    func expectAudiobookMatches(_ expected: AudiobookRecord) throws {
        let actual = try #require(try audiobookDAO.get(expected.id))
        #expect(actual.id == expected.id)
        #expect(actual.title == expected.title)
        #expect(actual.author == expected.author)
        #expect(actual.duration == expected.duration)
        #expect(actual.fileCount == expected.fileCount)
        #expect(actual.coverArtPath == expected.coverArtPath)
        #expect(actual.textOrigin == expected.textOrigin)
    }

    nonisolated private static func makeManifest(
        anthologyID: UUID
    ) -> AnthologyBuildManifest {
        let block = ArticleBlock(
            id: "article-block",
            stableOrdinal: 0,
            kind: .paragraph,
            text: "A frozen article.",
            sourceURL: nil,
            imageCandidateURL: nil,
            caption: nil,
            codeLanguage: nil)
        return AnthologyBuildManifest(
            schemaVersion: 1,
            anthologyID: anthologyID,
            revision: 1,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)",
            title: "A Small Book",
            subtitle: "Collected articles",
            creator: "Echo Editor",
            language: "en",
            coverPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_775_000_000),
            chapters: [
                AnthologyChapterManifest(
                    entryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    captureID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    articleRevisionID: UUID(
                        uuidString: "33333333-3333-3333-3333-333333333333")!,
                    stableSlot: 0,
                    order: 0,
                    title: "Article One",
                    author: "Writer",
                    siteName: "Example",
                    sourceURL: URL(string: "https://example.test/article")!,
                    capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
                    voiceID: nil,
                    blocks: [block],
                    readableContentSHA256: ArticleWorkshopDigest.readableContent(
                        blocks: [block]))
            ])
    }

    nonisolated private static func manifestSHA256(
        _ manifest: AnthologyBuildManifest
    ) -> String {
        sha256(Data(manifestJSON(manifest).utf8))
    }

    nonisolated private static func manifestJSON(
        _ manifest: AnthologyBuildManifest
    ) -> String {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(manifest), as: UTF8.self)
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum FixtureError: Swift.Error {
    case injected
    case secondBuilderInvocation
}

private actor AnthologyBuildPause {
    private var paused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuations: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        let observers = observerContinuations
        observerContinuations.removeAll()
        for observer in observers {
            observer.resume()
        }
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in
            observerContinuations.append(continuation)
        }
    }

    func release() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

private nonisolated final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
