// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation
import GRDB

nonisolated struct AnthologyLibraryImportReceipt: Sendable {
    let audiobookID: String
    let generatedRollbackSnapshot: GeneratedAnthologyImportRollbackSnapshot?

    init(
        audiobookID: String,
        generatedRollbackSnapshot: GeneratedAnthologyImportRollbackSnapshot? = nil
    ) {
        self.audiobookID = audiobookID
        self.generatedRollbackSnapshot = generatedRollbackSnapshot
    }
}

nonisolated enum AnthologyEPUBStatus: Equatable, Sendable {
    case notBuilt
    case building
    case ready(revision: Int)
    case changesAvailable(builtRevision: Int)
    case failed(previousRevision: Int?)
}

nonisolated struct AnthologyEPUBSnapshot: Equatable, Sendable {
    let status: AnthologyEPUBStatus
    let finalURL: URL?
    let audiobookID: String?
}

nonisolated enum AnthologyPublicationFaultPoint: Hashable, Sendable {
    case afterFirstPublishBeforeSync
    case afterReplacementBeforeSync
    case beforeReplacementRecoverySwap
    case beforeFirstRecoverySync
    case beforeReplacementRecoverySync
}

actor AnthologyBuildService {
    nonisolated enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case invalidAnthology
        case buildAlreadyInProgress
        case unsafeManagedPath
        case invalidBuildResult
        case publicationRecoveryFailed
        case libraryRecoveryFailed
        case buildFailed

        var errorDescription: String? {
            switch self {
            case .invalidAnthology:
                return "This anthology could not be prepared safely."
            case .buildAlreadyInProgress:
                return "This anthology is already building an EPUB."
            case .unsafeManagedPath:
                return "Echo could not access the managed edition safely."
            case .invalidBuildResult:
                return "The EPUB did not pass Echo’s safety checks."
            case .publicationRecoveryFailed:
                return "Echo could not safely restore the previous edition."
            case .libraryRecoveryFailed:
                return "Echo restored the prior file, but could not restore its library state."
            case .buildFailed:
                return "The EPUB could not be built. Try again."
            }
        }
    }

    nonisolated struct Dependencies: Sendable {
        let freezeManifest: @Sendable (String) throws -> AnthologyBuildManifest
        let buildEPUB: @Sendable (AnthologyBuildManifest, URL) throws -> AnthologyEPUBBuildResult
        let preflight: @Sendable (AnthologyEPUBBuildResult, AnthologyBuildManifest) throws -> Void
        let importEPUB: @Sendable (URL, URL, String) async throws -> AnthologyLibraryImportReceipt
        let importGeneratedEPUB:
            (
                @Sendable (
                    URL, String, GeneratedAnthologyImportIdentity
                ) async throws -> AnthologyLibraryImportReceipt
            )?
        let saveBuild: (@Sendable (AnthologyBuildRecord) throws -> Void)?
        let loadAudiobook: (@Sendable (String) throws -> AudiobookRecord?)?
        let saveAudiobook: (@Sendable (AudiobookRecord) throws -> Void)?
        let deleteAudiobook: (@Sendable (String) throws -> Void)?
        let restoreImport: (@Sendable (URL, URL, String) async throws -> Void)?
        let restoreGeneratedImport:
            (
                @Sendable (
                    URL, String, GeneratedAnthologyImportIdentity
                ) async throws -> Void
            )?
        let publicationFaultInjector: (@Sendable (AnthologyPublicationFaultPoint) throws -> Void)?

        init(
            freezeManifest:
                @escaping @Sendable (String) throws -> AnthologyBuildManifest,
            buildEPUB:
                @escaping @Sendable (
                    AnthologyBuildManifest, URL
                ) throws -> AnthologyEPUBBuildResult,
            preflight:
                @escaping @Sendable (
                    AnthologyEPUBBuildResult, AnthologyBuildManifest
                ) throws -> Void,
            importEPUB:
                @escaping @Sendable (
                    URL, URL, String
                ) async throws -> AnthologyLibraryImportReceipt,
            importGeneratedEPUB:
                (
                    @Sendable (
                        URL, String, GeneratedAnthologyImportIdentity
                    ) async throws -> AnthologyLibraryImportReceipt
                )? = nil,
            saveBuild: (@Sendable (AnthologyBuildRecord) throws -> Void)? = nil,
            loadAudiobook: (@Sendable (String) throws -> AudiobookRecord?)? = nil,
            saveAudiobook: (@Sendable (AudiobookRecord) throws -> Void)? = nil,
            deleteAudiobook: (@Sendable (String) throws -> Void)? = nil,
            restoreImport:
                (@Sendable (URL, URL, String) async throws -> Void)? = nil,
            restoreGeneratedImport:
                (
                    @Sendable (
                        URL, String, GeneratedAnthologyImportIdentity
                    ) async throws -> Void
                )? = nil,
            publicationFaultInjector:
                (@Sendable (AnthologyPublicationFaultPoint) throws -> Void)? = nil
        ) {
            self.freezeManifest = freezeManifest
            self.buildEPUB = buildEPUB
            self.preflight = preflight
            self.importEPUB = importEPUB
            self.importGeneratedEPUB = importGeneratedEPUB
            self.saveBuild = saveBuild
            self.loadAudiobook = loadAudiobook
            self.saveAudiobook = saveAudiobook
            self.deleteAudiobook = deleteAudiobook
            self.restoreImport = restoreImport
            self.restoreGeneratedImport = restoreGeneratedImport
            self.publicationFaultInjector = publicationFaultInjector
        }
    }

    private let workshopRoot: URL
    private let databaseWriter: DatabaseWriter
    private let dependencies: Dependencies
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private var inFlightAnthologyIDs: Set<String> = []

    @MainActor
    init(
        workshopRoot: URL = FileLocations.articleWorkshopRootDirectory,
        anthologyService: AnthologyService,
        databaseService: DatabaseService,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        let writer = databaseService.writer
        let builder = AnthologyEPUBBuilder(workshopRoot: workshopRoot)
        let preflight = AnthologyEPUBPreflight()
        self.workshopRoot = workshopRoot
        databaseWriter = writer
        dependencies = Dependencies(
            freezeManifest: { anthologyID in
                try anthologyService.prepareManifest(anthologyID: anthologyID)
            },
            buildEPUB: { manifest, destination in
                try builder.build(manifest: manifest, to: destination)
            },
            preflight: { result, manifest in
                try preflight.validate(result: result, against: manifest)
            },
            importEPUB: { finalURL, editionDirectory, audiobookID in
                let result = try await EPUBImportCoordinator.importEPUB(
                    from: finalURL,
                    to: editionDirectory,
                    databaseService: databaseService,
                    chapters: [],
                    duration: nil,
                    audiobookID: audiobookID,
                    networkPolicy: .localOnly)
                return AnthologyLibraryImportReceipt(audiobookID: result.audiobookID)
            },
            importGeneratedEPUB: { finalURL, audiobookID, identity in
                try await GeneratedAnthologyImportReconciler.importArchive(
                    at: finalURL,
                    audiobookID: audiobookID,
                    identity: identity,
                    databaseService: databaseService)
            },
            restoreImport: { finalURL, editionDirectory, audiobookID in
                _ = try await EPUBImportCoordinator.importEPUB(
                    from: finalURL,
                    to: editionDirectory,
                    databaseService: databaseService,
                    chapters: [],
                    duration: nil,
                    audiobookID: audiobookID,
                    networkPolicy: .localOnly)
            },
            restoreGeneratedImport: { finalURL, audiobookID, identity in
                _ = try await GeneratedAnthologyImportReconciler.importArchive(
                    at: finalURL,
                    audiobookID: audiobookID,
                    identity: identity,
                    databaseService: databaseService)
            })
        self.now = now
        self.makeID = makeID
    }

    @MainActor
    init(
        workshopRoot: URL,
        databaseService: DatabaseService,
        dependencies: Dependencies,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.workshopRoot = workshopRoot
        databaseWriter = databaseService.writer
        self.dependencies = dependencies
        self.now = now
        self.makeID = makeID
    }

    func build(anthologyID: String) async throws -> AnthologyBuildRecord {
        guard inFlightAnthologyIDs.insert(anthologyID).inserted else {
            throw Error.buildAlreadyInProgress
        }
        defer {
            inFlightAnthologyIDs.remove(anthologyID)
        }

        let manifest: AnthologyBuildManifest
        do {
            manifest = try dependencies.freezeManifest(anthologyID)
            guard manifest.anthologyID.uuidString == anthologyID else {
                throw Error.invalidAnthology
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidAnthology
        }

        let manifestEvidence: (json: String, sha256: String)
        do {
            manifestEvidence = try Self.manifestEvidence(manifest)
        } catch {
            throw Error.invalidAnthology
        }

        let editionDirectory: URL
        do {
            editionDirectory = try ManagedEditionStore(workshopRoot: workshopRoot)
                .prepareEditionDirectory(for: manifest.anthologyID)
        } catch {
            try? recordFailure(
                manifest: manifest,
                evidence: manifestEvidence,
                errorCode: "unsafe_managed_path")
            throw Error.unsafeManagedPath
        }

        let finalURL = editionDirectory.appending(path: "book.epub")
        let temporaryID = makeID().uuidString
        let temporaryURL = editionDirectory.appending(
            path: ".book-\(temporaryID).epub")
        let rollbackURL = editionDirectory.appending(
            path: ".book-\(temporaryID).rollback")
        let audiobookID = editionDirectory.standardizedFileURL.absoluteString
        let previousAudiobook: AudiobookRecord?
        let previousGeneratedIdentity: GeneratedAnthologyImportIdentity?
        do {
            previousAudiobook = try loadAudiobook(audiobookID)
            previousGeneratedIdentity =
                try previousAudiobook == nil
                ? nil
                : loadPriorGeneratedIdentity(
                    anthologyID: manifest.anthologyID,
                    audiobookID: audiobookID)
            if previousAudiobook != nil,
                dependencies.importGeneratedEPUB != nil,
                previousGeneratedIdentity == nil
            {
                throw Error.buildFailed
            }
        } catch {
            try? recordFailure(
                manifest: manifest,
                evidence: manifestEvidence,
                errorCode: "library_state_unavailable")
            throw Error.buildFailed
        }
        var publication: ManagedEditionStore.Publication?
        var libraryTouched = false
        var generatedImportCommitted = false
        var generatedRollbackSnapshot: GeneratedAnthologyImportRollbackSnapshot?

        do {
            let store = ManagedEditionStore(
                workshopRoot: workshopRoot,
                faultInjector: dependencies.publicationFaultInjector)
            try store.requireAbsentOwnedTemporary(temporaryURL, in: editionDirectory)
            try store.requireAbsentOwnedTemporary(rollbackURL, in: editionDirectory)
            let result = try dependencies.buildEPUB(manifest, temporaryURL)
            try validate(
                result: result,
                manifest: manifest,
                manifestSHA256: manifestEvidence.sha256,
                expectedTemporaryURL: temporaryURL,
                editionDirectory: editionDirectory)
            try dependencies.preflight(result, manifest)
            try store.validateRegularFile(
                at: temporaryURL,
                expectedSHA256: result.epubSHA256,
                in: editionDirectory)

            publication = try store.publish(
                temporaryURL: temporaryURL,
                finalURL: finalURL,
                rollbackURL: rollbackURL,
                in: editionDirectory)

            let record = Self.libraryRecord(
                prior: previousAudiobook,
                audiobookID: audiobookID,
                manifest: manifest,
                workshopRoot: workshopRoot,
                now: now())
            try saveAudiobook(record)
            libraryTouched = true

            let generatedIdentity = try GeneratedAnthologyImportIdentity(manifest: manifest)
            let importReceipt: AnthologyLibraryImportReceipt
            if let importGeneratedEPUB = dependencies.importGeneratedEPUB {
                importReceipt = try await importGeneratedEPUB(
                    finalURL,
                    audiobookID,
                    generatedIdentity)
                generatedImportCommitted = true
                generatedRollbackSnapshot = importReceipt.generatedRollbackSnapshot
                guard generatedRollbackSnapshot != nil else {
                    throw Error.invalidBuildResult
                }
            } else {
                importReceipt = try await dependencies.importEPUB(
                    finalURL,
                    editionDirectory,
                    audiobookID)
            }
            guard importReceipt.audiobookID == audiobookID else {
                throw Error.invalidBuildResult
            }
            try store.validateRegularFile(
                at: finalURL,
                expectedSHA256: result.epubSHA256,
                in: editionDirectory)

            let receipt = AnthologyBuildRecord(
                id: makeID().uuidString,
                anthologyID: anthologyID,
                revision: manifest.revision,
                epubIdentifier: manifest.epubIdentifier,
                manifestJSON: manifestEvidence.json,
                manifestSHA256: manifestEvidence.sha256,
                epubPath: finalURL.path,
                epubSHA256: result.epubSHA256,
                audiobookID: audiobookID,
                status: "succeeded",
                errorCode: nil,
                createdAt: Self.timestamp(now()))
            try saveBuild(receipt)
            if let publication {
                try? store.finish(publication, in: editionDirectory)
            }
            return receipt
        } catch {
            let store = ManagedEditionStore(workshopRoot: workshopRoot)
            if let publication {
                try? store.rollback(publication, in: editionDirectory)
            }
            var recoveryFailed = false
            if libraryTouched {
                do {
                    try await restoreAudiobook(
                        previousAudiobook,
                        audiobookID: audiobookID,
                        finalURL: finalURL,
                        editionDirectory: editionDirectory,
                        generatedIdentity: previousGeneratedIdentity,
                        generatedImportCommitted: generatedImportCommitted,
                        rollbackSnapshot: generatedRollbackSnapshot)
                } catch {
                    recoveryFailed = true
                }
            }
            try? store.removeValidatedTemporary(temporaryURL, in: editionDirectory)
            let reportedError: Error =
                recoveryFailed
                ? .libraryRecoveryFailed
                : ((error as? Error) ?? .buildFailed)
            let failureCode =
                recoveryFailed
                ? Self.errorCode(Error.libraryRecoveryFailed)
                : Self.errorCode(error)
            try? recordFailure(
                manifest: manifest,
                evidence: manifestEvidence,
                errorCode: failureCode)
            throw reportedError
        }
    }

    func snapshot(
        anthologyID: String,
        changesAvailable: Bool
    ) throws -> AnthologyEPUBSnapshot {
        guard let anthologyUUID = UUID(uuidString: anthologyID),
            anthologyUUID.uuidString == anthologyID
        else {
            throw Error.invalidAnthology
        }
        let records = try databaseWriter.read { database in
            let successful = try AnthologyBuildRecord.fetchOne(
                database,
                sql: """
                    SELECT * FROM anthology_build
                    WHERE anthology_id = ? AND status = 'succeeded'
                    ORDER BY revision DESC, rowid DESC
                    LIMIT 1
                    """,
                arguments: [anthologyID])
            let latestAttempt = try AnthologyBuildRecord.fetchOne(
                database,
                sql: """
                    SELECT * FROM anthology_build
                    WHERE anthology_id = ?
                    ORDER BY rowid DESC
                    LIMIT 1
                    """,
                arguments: [anthologyID])
            let audiobook =
                successful?.audiobookID.flatMap {
                    try? AudiobookRecord.fetchOne(database, key: $0)
                } ?? nil
            return (successful, latestAttempt, audiobook)
        }

        let coherent = try validatedOutput(
            successful: records.0,
            audiobook: records.2,
            anthologyID: anthologyUUID)
        let priorRevision = coherent.map(\.revision)
        let latestFailed =
            records.1?.status == "failed"
            && records.1?.id != records.0?.id

        let status: AnthologyEPUBStatus
        if inFlightAnthologyIDs.contains(anthologyID) {
            status = .building
        } else if latestFailed {
            status = .failed(previousRevision: priorRevision)
        } else if let priorRevision {
            status =
                changesAvailable
                ? .changesAvailable(builtRevision: priorRevision)
                : .ready(revision: priorRevision)
        } else if records.0 != nil {
            status = .failed(previousRevision: nil)
        } else {
            status = .notBuilt
        }
        return AnthologyEPUBSnapshot(
            status: status,
            finalURL: coherent?.finalURL,
            audiobookID: coherent?.audiobookID)
    }

    private func validatedOutput(
        successful: AnthologyBuildRecord?,
        audiobook: AudiobookRecord?,
        anthologyID: UUID
    ) throws -> (revision: Int, finalURL: URL, audiobookID: String)? {
        guard let successful,
            successful.status == "succeeded",
            successful.revision > 0,
            let epubPath = successful.epubPath,
            let epubSHA256 = successful.epubSHA256,
            Self.validSHA256(epubSHA256),
            let audiobookID = successful.audiobookID,
            let audiobook,
            audiobook.id == audiobookID,
            audiobook.isAvailable,
            audiobook.textOrigin == "epub",
            let manifestData = successful.manifestJSON.data(using: .utf8),
            let manifest = try? JSONDecoder.articleWorkshop.decode(
                AnthologyBuildManifest.self,
                from: manifestData),
            manifest.anthologyID == anthologyID,
            manifest.revision == successful.revision,
            manifest.epubIdentifier == successful.epubIdentifier,
            try Self.manifestEvidence(manifest).sha256 == successful.manifestSHA256
        else {
            return nil
        }

        do {
            let store = ManagedEditionStore(workshopRoot: workshopRoot)
            let editionDirectory = try store.validatedEditionDirectory(for: anthologyID)
            let finalURL = editionDirectory.appending(path: "book.epub")
            guard
                finalURL.standardizedFileURL.path
                    == URL(fileURLWithPath: epubPath)
                    .standardizedFileURL.path,
                audiobookID == editionDirectory.standardizedFileURL.absoluteString
            else {
                return nil
            }
            try store.validateRegularFile(
                at: finalURL,
                expectedSHA256: epubSHA256,
                in: editionDirectory)
            return (successful.revision, finalURL, audiobookID)
        } catch {
            return nil
        }
    }

    private func validate(
        result: AnthologyEPUBBuildResult,
        manifest: AnthologyBuildManifest,
        manifestSHA256: String,
        expectedTemporaryURL: URL,
        editionDirectory: URL
    ) throws {
        guard result.temporaryURL.standardizedFileURL == expectedTemporaryURL.standardizedFileURL,
            result.temporaryURL.deletingLastPathComponent().standardizedFileURL
                == editionDirectory.standardizedFileURL,
            result.identifier == manifest.epubIdentifier,
            result.revision == manifest.revision,
            result.manifestSHA256 == manifestSHA256,
            Self.validSHA256(result.epubSHA256)
        else {
            throw Error.invalidBuildResult
        }
    }

    private func recordFailure(
        manifest: AnthologyBuildManifest,
        evidence: (json: String, sha256: String),
        errorCode: String
    ) throws {
        try saveBuild(
            AnthologyBuildRecord(
                id: makeID().uuidString,
                anthologyID: manifest.anthologyID.uuidString,
                revision: manifest.revision,
                epubIdentifier: manifest.epubIdentifier,
                manifestJSON: evidence.json,
                manifestSHA256: evidence.sha256,
                epubPath: nil,
                epubSHA256: nil,
                audiobookID: nil,
                status: "failed",
                errorCode: errorCode,
                createdAt: Self.timestamp(now())))
    }

    private func loadAudiobook(_ id: String) throws -> AudiobookRecord? {
        if let load = dependencies.loadAudiobook {
            return try load(id)
        }
        return try databaseWriter.read { database in
            try AudiobookRecord.fetchOne(database, key: id)
        }
    }

    private func saveAudiobook(_ record: AudiobookRecord) throws {
        if let save = dependencies.saveAudiobook {
            try save(record)
        } else {
            var record = record
            try databaseWriter.write { database in
                try record.save(database)
            }
        }
    }

    private func deleteAudiobook(_ id: String) throws {
        if let delete = dependencies.deleteAudiobook {
            try delete(id)
        } else {
            _ = try databaseWriter.write { database in
                try AudiobookRecord.deleteOne(database, key: id)
            }
        }
    }

    private func saveBuild(_ record: AnthologyBuildRecord) throws {
        if let save = dependencies.saveBuild {
            try save(record)
        } else {
            try AnthologyDAO(db: databaseWriter).saveBuild(record)
        }
    }

    private func restoreAudiobook(
        _ previous: AudiobookRecord?,
        audiobookID: String,
        finalURL: URL,
        editionDirectory: URL,
        generatedIdentity: GeneratedAnthologyImportIdentity?,
        generatedImportCommitted: Bool,
        rollbackSnapshot: GeneratedAnthologyImportRollbackSnapshot?
    ) async throws {
        if let previous {
            try saveAudiobook(previous)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                if generatedImportCommitted {
                    guard let generatedIdentity,
                        let restore = dependencies.restoreGeneratedImport,
                        let rollbackSnapshot
                    else {
                        throw Error.libraryRecoveryFailed
                    }
                    try await restore(finalURL, audiobookID, generatedIdentity)
                    try await databaseWriter.write { database in
                        try rollbackSnapshot.restore(
                            audiobookID: audiobookID,
                            in: database)
                    }
                } else if dependencies.importGeneratedEPUB == nil,
                    let restore = dependencies.restoreImport
                {
                    try await restore(finalURL, editionDirectory, audiobookID)
                }
            }
        } else {
            try deleteAudiobook(audiobookID)
        }
    }

    private func loadPriorGeneratedIdentity(
        anthologyID: UUID,
        audiobookID: String
    ) throws -> GeneratedAnthologyImportIdentity? {
        let record = try databaseWriter.read { database in
            try AnthologyBuildRecord.fetchOne(
                database,
                sql: """
                    SELECT * FROM anthology_build
                    WHERE anthology_id = ?
                      AND audiobook_id = ?
                      AND status = 'succeeded'
                    ORDER BY revision DESC, rowid DESC
                    LIMIT 1
                    """,
                arguments: [anthologyID.uuidString, audiobookID])
        }
        guard let record,
            let data = record.manifestJSON.data(using: .utf8),
            let manifest = try? JSONDecoder.articleWorkshop.decode(
                AnthologyBuildManifest.self,
                from: data),
            manifest.anthologyID == anthologyID,
            manifest.revision == record.revision,
            manifest.epubIdentifier == record.epubIdentifier,
            try Self.manifestEvidence(manifest).sha256 == record.manifestSHA256
        else {
            return nil
        }
        return try GeneratedAnthologyImportIdentity(manifest: manifest)
    }

    private nonisolated static func libraryRecord(
        prior: AudiobookRecord?,
        audiobookID: String,
        manifest: AnthologyBuildManifest,
        workshopRoot: URL,
        now: Date
    ) -> AudiobookRecord {
        var record =
            prior
            ?? AudiobookRecord(
                id: audiobookID,
                title: manifest.title,
                author: manifest.creator,
                duration: 0,
                fileCount: 0,
                addedAt: timestamp(now))
        record.title = manifest.title
        record.author = manifest.creator
        record.duration = 0
        record.fileCount = 0
        record.isAvailable = true
        record.textOrigin = "epub"
        record.coverArtPath = managedCoverPath(
            manifest: manifest,
            workshopRoot: workshopRoot)
        return record
    }

    private nonisolated static func managedCoverPath(
        manifest: AnthologyBuildManifest,
        workshopRoot: URL
    ) -> String? {
        guard let name = manifest.coverPath,
            name.isEmpty == false,
            name != ".",
            name != "..",
            name.contains("/") == false,
            name.contains("\\") == false,
            URL(fileURLWithPath: name).lastPathComponent == name
        else {
            return nil
        }
        return
            workshopRoot
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: manifest.anthologyID.uuidString, directoryHint: .isDirectory)
            .appending(path: name)
            .standardizedFileURL.path
    }

    private nonisolated static func manifestEvidence(
        _ manifest: AnthologyBuildManifest
    ) throws -> (json: String, sha256: String) {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        return (
            String(decoding: data, as: UTF8.self),
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private nonisolated static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private nonisolated static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.timeZone(separator: .omitted))
    }

    private nonisolated static func errorCode(_ error: Swift.Error) -> String {
        switch error {
        case AnthologyEPUBBuilder.Error.missingImageAssetMapping:
            return "missing_image_asset_mapping"
        case is AnthologyEPUBBuilder.Error:
            return "epub_build_failed"
        case is AnthologyEPUBPreflight.Error:
            return "epub_preflight_failed"
        case Error.unsafeManagedPath:
            return "unsafe_managed_path"
        case Error.invalidBuildResult:
            return "invalid_build_result"
        case Error.publicationRecoveryFailed:
            return "publication_recovery_failed"
        case Error.libraryRecoveryFailed:
            return "library_recovery_failed"
        default:
            return "build_failed"
        }
    }
}

private nonisolated struct ManagedEditionStore: Sendable {
    struct Publication: Sendable {
        let temporaryURL: URL
        let finalURL: URL
        let rollbackURL: URL?
    }

    let workshopRoot: URL
    let faultInjector: (@Sendable (AnthologyPublicationFaultPoint) throws -> Void)?

    init(
        workshopRoot: URL,
        faultInjector:
            (@Sendable (AnthologyPublicationFaultPoint) throws -> Void)? = nil
    ) {
        self.workshopRoot = workshopRoot
        self.faultInjector = faultInjector
    }

    func validatedEditionDirectory(for anthologyID: UUID) throws -> URL {
        try requireDirectory(workshopRoot)
        let editions = workshopRoot.appending(path: "Editions", directoryHint: .isDirectory)
        try requireDirectory(editions)
        let edition = editions.appending(
            path: anthologyID.uuidString,
            directoryHint: .isDirectory)
        try requireDirectory(edition)
        guard
            edition.deletingLastPathComponent().standardizedFileURL
                == editions.standardizedFileURL
        else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        return edition
    }

    func prepareEditionDirectory(for anthologyID: UUID) throws -> URL {
        try ensureDirectory(workshopRoot)
        let editions = workshopRoot.appending(path: "Editions", directoryHint: .isDirectory)
        try ensureDirectory(editions)
        let edition = editions.appending(
            path: anthologyID.uuidString,
            directoryHint: .isDirectory)
        try ensureDirectory(edition)
        guard
            edition.deletingLastPathComponent().standardizedFileURL
                == editions.standardizedFileURL
        else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        return edition
    }

    func requireAbsentOwnedTemporary(_ url: URL, in directory: URL) throws {
        try requireDirectChild(url, of: directory)
        var metadata = stat()
        guard lstat(url.path, &metadata) != 0, errno == ENOENT else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
    }

    func validateRegularFile(
        at url: URL,
        expectedSHA256: String,
        in directory: URL
    ) throws {
        try requireDirectChild(url, of: directory)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0
        else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            digest.finalize().map({ String(format: "%02x", $0) }).joined()
                == expectedSHA256
        else {
            throw AnthologyBuildService.Error.invalidBuildResult
        }
    }

    func publish(
        temporaryURL: URL,
        finalURL: URL,
        rollbackURL: URL,
        in directory: URL
    ) throws -> Publication {
        try requireDirectChild(temporaryURL, of: directory)
        try requireDirectChild(finalURL, of: directory)
        try requireDirectChild(rollbackURL, of: directory)
        try requireAbsentOwnedTemporary(rollbackURL, in: directory)
        let replacedPrevious = try existingRegularFile(finalURL)
        if replacedPrevious {
            guard rename(temporaryURL.path, rollbackURL.path) == 0 else {
                throw AnthologyBuildService.Error.unsafeManagedPath
            }
            guard exchange(rollbackURL, finalURL) == 0 else {
                if rename(rollbackURL.path, temporaryURL.path) != 0 {
                    try? removeValidatedTemporary(rollbackURL, in: directory)
                }
                throw AnthologyBuildService.Error.unsafeManagedPath
            }
            do {
                try faultInjector?(.afterReplacementBeforeSync)
                try sync(directory)
            } catch {
                do {
                    try recoverReplacementPublication(
                        temporaryURL: temporaryURL,
                        finalURL: finalURL,
                        rollbackURL: rollbackURL,
                        in: directory)
                } catch {
                    throw AnthologyBuildService.Error.publicationRecoveryFailed
                }
                throw error
            }
        } else {
            guard rename(temporaryURL.path, finalURL.path) == 0 else {
                throw AnthologyBuildService.Error.unsafeManagedPath
            }
            do {
                try faultInjector?(.afterFirstPublishBeforeSync)
                try sync(directory)
            } catch {
                if rename(finalURL.path, temporaryURL.path) != 0 {
                    do {
                        try removeValidatedTemporary(finalURL, in: directory)
                    } catch {
                        throw AnthologyBuildService.Error.publicationRecoveryFailed
                    }
                }
                do {
                    try faultInjector?(.beforeFirstRecoverySync)
                    try sync(directory)
                } catch {
                    throw AnthologyBuildService.Error.publicationRecoveryFailed
                }
                throw error
            }
        }
        return Publication(
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            rollbackURL: replacedPrevious ? rollbackURL : nil)
    }

    private func recoverReplacementPublication(
        temporaryURL: URL,
        finalURL: URL,
        rollbackURL: URL,
        in directory: URL
    ) throws {
        do {
            try faultInjector?(.beforeReplacementRecoverySwap)
            guard exchange(rollbackURL, finalURL) == 0 else {
                throw AnthologyBuildService.Error.unsafeManagedPath
            }
        } catch {
            guard rename(finalURL.path, temporaryURL.path) == 0,
                rename(rollbackURL.path, finalURL.path) == 0
            else {
                throw AnthologyBuildService.Error.publicationRecoveryFailed
            }
            try removeValidatedTemporary(temporaryURL, in: directory)
            try faultInjector?(.beforeReplacementRecoverySync)
            try sync(directory)
            return
        }
        try removeValidatedTemporary(rollbackURL, in: directory)
        try faultInjector?(.beforeReplacementRecoverySync)
        try sync(directory)
    }

    private func exchange(_ first: URL, _ second: URL) -> Int32 {
        first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP))
            }
        }
    }

    func rollback(_ publication: Publication, in directory: URL) throws {
        try requireDirectChild(publication.temporaryURL, of: directory)
        try requireDirectChild(publication.finalURL, of: directory)
        if let rollbackURL = publication.rollbackURL {
            try requireDirectChild(rollbackURL, of: directory)
            guard try existingRegularFile(rollbackURL),
                try existingRegularFile(publication.finalURL)
            else {
                throw AnthologyBuildService.Error.unsafeManagedPath
            }
            let result = rollbackURL.path.withCString { rollbackPath in
                publication.finalURL.path.withCString { finalPath in
                    renameatx_np(
                        AT_FDCWD,
                        rollbackPath,
                        AT_FDCWD,
                        finalPath,
                        UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else {
                throw AnthologyBuildService.Error.unsafeManagedPath
            }
            try removeValidatedTemporary(rollbackURL, in: directory)
        } else {
            try removeValidatedTemporary(publication.finalURL, in: directory)
        }
        try sync(directory)
    }

    func finish(_ publication: Publication, in directory: URL) throws {
        guard let rollbackURL = publication.rollbackURL else { return }
        try removeValidatedTemporary(rollbackURL, in: directory)
        try sync(directory)
    }

    func removeValidatedTemporary(_ url: URL, in directory: URL) throws {
        try requireDirectChild(url, of: directory)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        guard unlink(url.path) == 0 else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw AnthologyBuildService.Error.unsafeManagedPath
            }
            return
        }
        guard errno == ENOENT else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false)
        } catch {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        guard lstat(url.path, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
    }

    private func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
    }

    private func requireDirectChild(_ url: URL, of directory: URL) throws {
        guard
            url.standardizedFileURL.deletingLastPathComponent()
                == directory.standardizedFileURL,
            url.lastPathComponent != ".",
            url.lastPathComponent != "..",
            url.lastPathComponent.contains("/") == false
        else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
    }

    private func existingRegularFile(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return false }
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        return true
    }

    private func sync(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AnthologyBuildService.Error.unsafeManagedPath
        }
    }
}
