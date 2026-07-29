// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import Foundation

nonisolated protocol ArticleSyncEngineDriver: Sendable {
    func schedule(_ changes: [ArticlePendingCloudChange]) async
    func fetchChanges() async throws
    func sendChanges() async throws
}

nonisolated enum ArticleSyncFailureCode: String, Equatable, Sendable {
    case quota
    case network
    case serverRecordConflict
    case authentication
    case missingZone
    case partialFailure
    case localPersistence
    case invalidRemoteRecord
    case notStarted
    case unknown

    static func classify(_ error: CKError) -> ArticleSyncFailureCode {
        switch error.code {
        case .quotaExceeded:
            .quota
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
            .requestRateLimited, .zoneBusy:
            .network
        case .serverRecordChanged:
            .serverRecordConflict
        case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure:
            .authentication
        case .zoneNotFound, .userDeletedZone:
            .missingZone
        case .partialFailure:
            .partialFailure
        default:
            .unknown
        }
    }
}

nonisolated enum ArticleSyncEngineError: Swift.Error, Equatable, Sendable {
    case notStarted
}

nonisolated struct ArticleFetchedCloudDeletion: Sendable {
    let recordID: CKRecord.ID
    let recordType: String
}

/// Copies every fetched asset out of CloudKit temporary storage, installs
/// capture packages and covers into managed storage, then commits the complete
/// fetched database batch in one transaction.
nonisolated struct ArticleFetchedCloudBatchApplier: Sendable {
    private let syncDAO: ArticleSyncDAO
    private let codec: ArticleCloudRecordCodec
    private let workshopRootDirectory: URL
    private let incomingDirectory: URL

    init(
        syncDAO: ArticleSyncDAO,
        codec: ArticleCloudRecordCodec,
        workshopRootDirectory: URL = FileLocations.articleWorkshopRootDirectory,
        incomingDirectory: URL = FileLocations.articleSyncTemporaryDirectory.appending(
            path: "Incoming",
            directoryHint: .isDirectory)
    ) {
        self.syncDAO = syncDAO
        self.codec = codec
        self.workshopRootDirectory = workshopRootDirectory
        self.incomingDirectory = incomingDirectory
    }

    func apply(
        modifications: [CKRecord],
        deletions: [ArticleFetchedCloudDeletion]
    ) throws {
        var decoded: [ArticleDecodedCloudRecord] = []
        var copiedAssetURLs: [URL] = []
        defer {
            for url in copiedAssetURLs where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for record in modifications {
            let value = try codec.decode(
                record,
                assetCopyDirectory: incomingDirectory)
            decoded.append(value)
            switch value {
            case .capture(let payload):
                copiedAssetURLs.append(payload.packageArchiveURL)
            case .revision:
                break
            case .anthology(let payload):
                if let coverURL = payload.coverURL {
                    copiedAssetURLs.append(coverURL)
                }
            }
        }

        var databaseChanges: [ArticleFetchedDatabaseChange] = []
        for value in decoded {
            switch value {
            case .capture(let payload):
                databaseChanges.append(
                    .capture(
                        try codec.installCapturePackage(
                            payload,
                            workshopRootDirectory: workshopRootDirectory)))
            case .revision(let payload):
                databaseChanges.append(.revision(payload.revision))
            case .anthology(let payload):
                var manifest = payload.manifest
                if let coverURL = payload.coverURL {
                    let targetID = try coverTargetID(for: manifest)
                    manifest.anthology.coverPath = try AnthologyCoverStore(
                        root: workshopRootDirectory
                    ).importCover(from: coverURL, anthologyID: targetID)
                }
                databaseChanges.append(.anthology(manifest))
            }
        }

        for deletion in deletions {
            let identity = try codec.deletedRecordIdentity(
                recordID: deletion.recordID,
                recordType: deletion.recordType)
            databaseChanges.append(
                .delete(
                    recordType: identity.type,
                    entityID: identity.entityID))
        }
        try syncDAO.applyFetchedChanges(databaseChanges)
    }

    private func coverTargetID(
        for incoming: ArticleCloudAnthologyManifest
    ) throws -> UUID {
        guard let incomingID = UUID(uuidString: incoming.anthology.id),
            incomingID.uuidString == incoming.anthology.id
        else {
            throw ArticleCloudRecordCodec.Error.invalidEntityID(incoming.anthology.id)
        }
        guard let existing = try syncDAO.anthologyManifest(id: incoming.anthology.id)
        else {
            return incomingID
        }
        if cloudComparable(existing) == cloudComparable(incoming) {
            return incomingID
        }
        return ArticleSyncConflictIdentity.recoveredAnthologyID(
            incoming: incoming,
            existing: existing)
    }

    private func cloudComparable(
        _ manifest: ArticleCloudAnthologyManifest
    ) -> ArticleCloudAnthologyManifest {
        var result = manifest
        result.anthology.coverPath = nil
        result.anthology.latestBuildRevision = 0
        return result
    }
}

/// Offline-first coordinator. Its initializer is CloudKit-free; production
/// container and engine construction happens only when `start()` is called.
nonisolated final class ArticleWorkshopCloudSyncEngine: Sendable {
    private let syncDAO: ArticleSyncDAO
    private let driver: any ArticleSyncEngineDriver
    private let startDriver: @Sendable () async throws -> Void
    private let cancelDriver: @Sendable () async -> Void

    init(
        syncDAO: ArticleSyncDAO,
        driver: any ArticleSyncEngineDriver
    ) {
        self.syncDAO = syncDAO
        self.driver = driver
        self.startDriver = {}
        self.cancelDriver = {}
    }

    private init(
        syncDAO: ArticleSyncDAO,
        driver: any ArticleSyncEngineDriver,
        startDriver: @escaping @Sendable () async throws -> Void,
        cancelDriver: @escaping @Sendable () async -> Void
    ) {
        self.syncDAO = syncDAO
        self.driver = driver
        self.startDriver = startDriver
        self.cancelDriver = cancelDriver
    }

    static func production(
        syncDAO: ArticleSyncDAO,
        temporaryDirectory: URL = FileLocations.articleSyncTemporaryDirectory
    ) -> ArticleWorkshopCloudSyncEngine {
        let productionDriver = ArticleCloudKitSyncEngineDriver(
            syncDAO: syncDAO,
            codec: ArticleCloudRecordCodec(temporaryDirectory: temporaryDirectory))
        return ArticleWorkshopCloudSyncEngine(
            syncDAO: syncDAO,
            driver: productionDriver,
            startDriver: { try await productionDriver.start() },
            cancelDriver: { await productionDriver.cancel() })
    }

    func start() async throws {
        try await startDriver()
        await driver.schedule(try syncDAO.pendingChanges())
    }

    func schedule(_ changes: [ArticlePendingCloudChange]) async {
        do {
            try syncDAO.enqueue(changes)
        } catch {
            do {
                try syncDAO.updateStatus(
                    .temporarilyUnavailable,
                    lastErrorCode: ArticleSyncFailureCode.localPersistence.rawValue,
                    updatedAt: Date().ISO8601Format())
            } catch {
                // The outbox write is already the failure boundary. There is no
                // safe second persistence surface to mutate here.
            }
            return
        }
        await driver.schedule(changes)
    }

    func fetchChanges() async throws {
        try await driver.fetchChanges()
    }

    func sendChanges() async throws {
        try await driver.sendChanges()
    }

    func cancel() async {
        await cancelDriver()
    }

    func acknowledgeSent(
        savedRecordNames: [String],
        deletedRecordNames: [String]
    ) throws {
        try syncDAO.acknowledgeSaved(recordNames: savedRecordNames)
        try syncDAO.acknowledgeDeleted(recordNames: deletedRecordNames)
    }
}

private actor ArticleCloudKitSyncEngineDriver: ArticleSyncEngineDriver, CKSyncEngineDelegate {
    private static let containerIdentifier = "iCloud.com.echo.audiobooks"

    private let syncDAO: ArticleSyncDAO
    private let codec: ArticleCloudRecordCodec
    private let batchApplier: ArticleFetchedCloudBatchApplier
    private var engine: CKSyncEngine?
    private var stagedAssets: [String: [URL]] = [:]

    init(syncDAO: ArticleSyncDAO, codec: ArticleCloudRecordCodec) {
        self.syncDAO = syncDAO
        self.codec = codec
        self.batchApplier = ArticleFetchedCloudBatchApplier(
            syncDAO: syncDAO,
            codec: codec)
    }

    func start() throws {
        guard engine == nil else { return }
        let storedState = try syncDAO.engineState()
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerIdentifier)
                .privateCloudDatabase,
            stateSerialization: storedState,
            delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: zoneID))
        ])
        let changes = try syncDAO.pendingChanges()
        engine.state.add(
            pendingRecordZoneChanges: changes.map(pendingEngineChange))
    }

    func schedule(_ changes: [ArticlePendingCloudChange]) async {
        guard let engine else { return }
        engine.state.add(
            pendingRecordZoneChanges: changes.map(pendingEngineChange))
    }

    func fetchChanges() async throws {
        guard let engine else { throw ArticleSyncEngineError.notStarted }
        try await engine.fetchChanges()
    }

    func sendChanges() async throws {
        guard let engine else { throw ArticleSyncEngineError.notStarted }
        try await engine.sendChanges()
    }

    func cancel() async {
        guard let engine else { return }
        await engine.cancelOperations()
        cleanupAllStagedAssets()
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persistState(update.stateSerialization)
        case .accountChange(let change):
            handleAccountChange(change)
        case .fetchedDatabaseChanges(let changes):
            handleFetchedDatabaseChanges(changes, syncEngine: syncEngine)
        case .fetchedRecordZoneChanges(let changes):
            handleFetchedRecordZoneChanges(changes)
        case .sentDatabaseChanges(let changes):
            handleSentDatabaseChanges(changes)
        case .sentRecordZoneChanges(let changes):
            handleSentRecordZoneChanges(changes)
        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                persist(error: error)
            }
        case .willFetchChanges, .willFetchRecordZoneChanges,
            .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending,
            recordProvider: { recordID in
                await self.recordToSave(recordID)
            })
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: ArticleCloudRecordCodec.zoneName,
            ownerName: CKCurrentUserDefaultName)
    }

    private func pendingEngineChange(
        _ change: ArticlePendingCloudChange
    ) -> CKSyncEngine.PendingRecordZoneChange {
        let recordID = CKRecord.ID(
            recordName: change.recordName,
            zoneID: zoneID)
        switch change.operation {
        case .save: return .saveRecord(recordID)
        case .delete: return .deleteRecord(recordID)
        }
    }

    private func recordToSave(_ recordID: CKRecord.ID) -> CKRecord? {
        guard recordID.zoneID == zoneID else { return nil }
        do {
            guard let change = try syncDAO.pendingChange(recordName: recordID.recordName),
                change.operation == .save
            else {
                return nil
            }
            cleanupStagedAssets(recordName: recordID.recordName)
            let record: CKRecord
            switch change.recordType {
            case .capture:
                guard let capture = try syncDAO.capture(id: change.entityID) else {
                    return nil
                }
                record = try codec.captureRecord(
                    capture,
                    packageDirectory: URL(
                        fileURLWithPath: capture.packagePath,
                        isDirectory: true))
            case .revision:
                guard let revision = try syncDAO.revision(id: change.entityID) else {
                    return nil
                }
                record = try codec.revisionRecord(revision)
            case .anthology:
                guard let manifest = try syncDAO.anthologyManifest(id: change.entityID) else {
                    return nil
                }
                guard let anthologyID = UUID(uuidString: manifest.anthology.id),
                    anthologyID.uuidString == manifest.anthology.id
                else {
                    return nil
                }
                let coverURL = manifest.anthology.coverPath.map {
                    FileLocations.articleAnthologyDirectory(id: anthologyID)
                        .appending(path: $0)
                }
                record = try codec.anthologyRecord(manifest, coverURL: coverURL)
            }
            stagedAssets[recordID.recordName] = record.allKeys().compactMap {
                (record[$0] as? CKAsset)?.fileURL
            }
            return record
        } catch {
            persist(stableCode: .localPersistence)
            return nil
        }
    }

    private func persistState(_ state: CKSyncEngine.State.Serialization) {
        do {
            try syncDAO.saveEngineState(
                state,
                updatedAt: Date().ISO8601Format())
        } catch {
            persist(stableCode: .localPersistence)
        }
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        let status: ArticleSyncAccountStatus
        switch event.changeType {
        case .signIn:
            status = .available
        case .signOut:
            status = .signedOut
        case .switchAccounts:
            status = .switchedAccount
        @unknown default:
            status = .unknown
        }
        do {
            try syncDAO.updateStatus(
                status,
                lastErrorCode: nil,
                updatedAt: Date().ISO8601Format())
        } catch {
            // Local workshop data is deliberately preserved even when its sync
            // status receipt cannot be updated.
        }
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        guard event.deletions.contains(where: { $0.zoneID == zoneID }) else { return }
        syncEngine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: zoneID))
        ])
        persist(stableCode: .missingZone)
    }

    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) {
        do {
            try batchApplier.apply(
                modifications: event.modifications.map(\.record),
                deletions: event.deletions.map {
                    ArticleFetchedCloudDeletion(
                        recordID: $0.recordID,
                        recordType: $0.recordType)
                })
        } catch {
            persist(stableCode: .invalidRemoteRecord)
        }
    }

    private func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges
    ) {
        if let failure = event.failedZoneSaves.first {
            persist(error: failure.error)
        } else if let error = event.failedZoneDeletes.values.first {
            persist(error: error)
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges
    ) {
        let saved = event.savedRecords.map(\.recordID.recordName)
        let deleted = event.deletedRecordIDs.map(\.recordName)
        do {
            try syncDAO.acknowledgeSaved(recordNames: saved)
            try syncDAO.acknowledgeDeleted(recordNames: deleted)
        } catch {
            persist(stableCode: .localPersistence)
        }
        for name in saved + deleted {
            cleanupStagedAssets(recordName: name)
        }

        let failures =
            event.failedRecordSaves.map(\.error)
            + Array(event.failedRecordDeletes.values)
        let failedNames =
            event.failedRecordSaves.map(\.record.recordID.recordName)
            + event.failedRecordDeletes.keys.map(\.recordName)
        for name in failedNames {
            cleanupStagedAssets(recordName: name)
        }
        if failures.isEmpty == false {
            let code: ArticleSyncFailureCode =
                failures.count > 1 ? .partialFailure : .classify(failures[0])
            persist(stableCode: code)
        }
    }

    private func persist(error: CKError) {
        persist(stableCode: .classify(error))
    }

    private func persist(stableCode: ArticleSyncFailureCode) {
        do {
            try syncDAO.updateStatus(
                stableCode == .authentication ? .temporarilyUnavailable : .unknown,
                lastErrorCode: stableCode.rawValue,
                updatedAt: Date().ISO8601Format())
        } catch {
            // Never emit the raw CloudKit error or private record contents.
        }
    }

    private func cleanupStagedAssets(recordName: String) {
        let urls = stagedAssets.removeValue(forKey: recordName) ?? []
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupAllStagedAssets() {
        let names = Array(stagedAssets.keys)
        for name in names {
            cleanupStagedAssets(recordName: name)
        }
    }
}
