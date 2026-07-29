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

nonisolated enum ArticleSyncFailureAction: Equatable, Sendable {
    case engineRetains
    case mergeServerAndRequeue
    case rebuildZone
    case acknowledgeMissingDelete
    case manualRequeue
    case waitForUser
    case quarantineLane
}

nonisolated enum ArticleSyncFailurePolicy {
    static func action(
        for code: CKError.Code,
        operation: ArticleSyncOperation
    ) -> ArticleSyncFailureAction {
        switch (code, operation) {
        case (.serverRecordChanged, .save):
            .mergeServerAndRequeue
        case (.zoneNotFound, .save), (.userDeletedZone, .save):
            .rebuildZone
        case (.unknownItem, .delete), (.zoneNotFound, .delete),
            (.userDeletedZone, .delete):
            .acknowledgeMissingDelete
        case (.notAuthenticated, _), (.accountTemporarilyUnavailable, _),
            (.networkFailure, _), (.networkUnavailable, _),
            (.requestRateLimited, _), (.serviceUnavailable, _),
            (.zoneBusy, _):
            .engineRetains
        case (.quotaExceeded, _):
            .waitForUser
        case (.permissionFailure, _), (.managedAccountRestricted, _),
            (.missingEntitlement, _), (.badContainer, _), (.badDatabase, _):
            .waitForUser
        default:
            .manualRequeue
        }
    }
}

nonisolated struct ArticleSyncFailedChangePlan: Equatable, Sendable {
    let action: ArticleSyncFailureAction
    let changeToRequeue: ArticlePendingCloudChange?
    let deleteToAcknowledge: ArticleCloudDeleteAcknowledgement?

    static func make(
        code: CKError.Code,
        change: ArticlePendingCloudChange?
    ) -> ArticleSyncFailedChangePlan {
        guard let change else {
            return ArticleSyncFailedChangePlan(
                action: .waitForUser,
                changeToRequeue: nil,
                deleteToAcknowledge: nil)
        }
        let action = ArticleSyncFailurePolicy.action(
            for: code,
            operation: change.operation)
        return ArticleSyncFailedChangePlan(
            action: action,
            changeToRequeue: action == .manualRequeue ? change : nil,
            deleteToAcknowledge:
                action == .acknowledgeMissingDelete
                ? ArticleCloudDeleteAcknowledgement(
                    recordName: change.recordName,
                    generation: change.generation)
                : nil)
    }
}

nonisolated enum ArticleSyncZoneDeletionPolicy {
    enum Action: Equatable, Sendable {
        case rebuildFromLocalAuthority
        case quarantineLane
    }

    static func action(
        for reason: CKDatabase.DatabaseChange.Deletion.Reason
    ) -> Action {
        switch reason {
        case .deleted:
            .rebuildFromLocalAuthority
        case .purged, .encryptedDataReset:
            .quarantineLane
        @unknown default:
            .quarantineLane
        }
    }
}

nonisolated enum ArticleSyncZoneRecoveryResult: Equatable, Sendable {
    case noAction
    case rebuild([ArticlePendingCloudChange])
    case quarantine
    case failed(ArticleSyncFailureCode)
}

nonisolated struct ArticleSyncZoneRecoveryHandler: Sendable {
    let syncDAO: ArticleSyncDAO

    func handle(
        deletionReasons: [CKDatabase.DatabaseChange.Deletion.Reason],
        updatedAt: String,
        fetchProgress: inout ArticleSyncFetchProgress
    ) -> ArticleSyncZoneRecoveryResult {
        guard deletionReasons.isEmpty == false else { return .noAction }
        if deletionReasons.contains(where: {
            ArticleSyncZoneDeletionPolicy.action(for: $0) == .quarantineLane
        }) {
            return .quarantine
        }
        do {
            return .rebuild(
                try syncDAO.recoverMissingZone(updatedAt: updatedAt))
        } catch {
            fetchProgress.recordApplyFailure(.localPersistence)
            return .failed(.localPersistence)
        }
    }
}

nonisolated struct ArticleSyncFetchProgress: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case applyFailed(ArticleSyncFailureCode)
    }

    private(set) var failure: ArticleSyncFailureCode?

    var shouldPersistState: Bool { failure == nil }

    mutating func recordApplyFailure(_ code: ArticleSyncFailureCode) {
        if failure == nil {
            failure = code
        }
    }

    mutating func recordApplySuccess() {
        // An engine epoch stays poisoned after any apply failure. A later event
        // cannot make a state-ahead-of-data checkpoint safe.
    }

    mutating func resetForNewEngineEpoch() {
        failure = nil
    }

    func throwIfFailed() throws {
        if let failure {
            throw Error.applyFailed(failure)
        }
    }
}

nonisolated struct ArticleSyncAccountEventHandler: Sendable {
    struct Result: Equatable, Sendable {
        let shouldSchedulePendingChanges: Bool
    }

    let syncDAO: ArticleSyncDAO

    func handle(
        _ changeType: CKSyncEngine.Event.AccountChange.ChangeType,
        updatedAt: String
    ) throws -> Result {
        switch changeType {
        case .signIn(let currentUser):
            let binding = try syncDAO.bindAccountOwner(
                currentUser.recordName,
                updatedAt: updatedAt)
            return Result(shouldSchedulePendingChanges: binding == .available)
        case .signOut:
            try syncDAO.unbindAccountOwner(
                status: .signedOut,
                updatedAt: updatedAt)
            return Result(shouldSchedulePendingChanges: false)
        case .switchAccounts(_, let currentUser):
            let binding = try syncDAO.bindAccountOwner(
                currentUser.recordName,
                updatedAt: updatedAt)
            return Result(shouldSchedulePendingChanges: binding == .available)
        @unknown default:
            try syncDAO.unbindAccountOwner(
                status: .unknown,
                updatedAt: updatedAt)
            return Result(shouldSchedulePendingChanges: false)
        }
    }
}

nonisolated enum ArticleSyncAccountEventPolicy {
    static func startsNewEngineEpoch(
        _ changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) -> Bool {
        switch changeType {
        case .signIn, .switchAccounts:
            true
        case .signOut:
            false
        @unknown default:
            false
        }
    }
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
    private let beforeDatabaseCommit: @Sendable () throws -> Void

    init(
        syncDAO: ArticleSyncDAO,
        codec: ArticleCloudRecordCodec,
        workshopRootDirectory: URL = FileLocations.articleWorkshopRootDirectory,
        incomingDirectory: URL = FileLocations.articleSyncTemporaryDirectory.appending(
            path: "Incoming",
            directoryHint: .isDirectory),
        beforeDatabaseCommit: @escaping @Sendable () throws -> Void = {}
    ) {
        self.syncDAO = syncDAO
        self.codec = codec
        self.workshopRootDirectory = workshopRootDirectory
        self.incomingDirectory = incomingDirectory
        self.beforeDatabaseCommit = beforeDatabaseCommit
    }

    func apply(
        modifications: [CKRecord],
        deletions: [ArticleFetchedCloudDeletion]
    ) throws {
        var decoded: [ArticleDecodedCloudRecord] = []
        var cloudReceipts: [ArticleFetchedCloudRecordReceipt] = []
        var copiedAssetURLs: [URL] = []
        var newlyInstalledURLs: [URL] = []
        var committed = false
        defer {
            for url in copiedAssetURLs where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            if committed == false {
                for url in newlyInstalledURLs.reversed()
                where FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        for record in modifications {
            let value = try codec.decode(
                record,
                assetCopyDirectory: incomingDirectory)
            decoded.append(value)
            let identity: (ArticleCloudRecordType, String)
            switch value {
            case .capture(let payload):
                copiedAssetURLs.append(payload.packageArchiveURL)
                identity = (.capture, payload.capture.id)
            case .revision(let payload):
                identity = (.revision, payload.revision.id)
            case .anthology(let payload):
                identity = (.anthology, payload.manifest.anthology.id)
                if let coverURL = payload.coverURL {
                    copiedAssetURLs.append(coverURL)
                }
            }
            cloudReceipts.append(
                ArticleFetchedCloudRecordReceipt(
                    recordName: record.recordID.recordName,
                    recordType: identity.0,
                    entityID: identity.1,
                    systemFields: try codec.systemFields(for: record),
                    contentFingerprint: try codec.contentFingerprint(for: record)))
        }

        var databaseChanges: [ArticleFetchedDatabaseChange] = []
        for value in decoded {
            switch value {
            case .capture(let payload):
                let destination =
                    workshopRootDirectory
                    .appending(path: "Captures", directoryHint: .isDirectory)
                    .appending(path: payload.capture.id, directoryHint: .isDirectory)
                let existed = FileManager.default.fileExists(atPath: destination.path)
                databaseChanges.append(
                    .capture(
                        try codec.installCapturePackage(
                            payload,
                            workshopRootDirectory: workshopRootDirectory)))
                if existed == false {
                    newlyInstalledURLs.append(destination)
                }
            case .revision(let payload):
                databaseChanges.append(.revision(payload.revision))
            case .anthology(let payload):
                var manifest = payload.manifest
                let disposition = try syncDAO.anthologyDisposition(for: manifest)
                if let coverURL = payload.coverURL {
                    guard
                        let targetID = UUID(
                            uuidString: disposition.targetAnthologyID),
                        targetID.uuidString == disposition.targetAnthologyID
                    else {
                        throw ArticleCloudRecordCodec.Error.invalidEntityID(
                            disposition.targetAnthologyID)
                    }
                    let anthologyDirectory =
                        workshopRootDirectory
                        .appending(path: "Anthologies", directoryHint: .isDirectory)
                        .appending(path: targetID.uuidString, directoryHint: .isDirectory)
                    let previousFiles =
                        (try? FileManager.default.contentsOfDirectory(
                            atPath: anthologyDirectory.path)) ?? []
                    let coverPath = try AnthologyCoverStore(
                        root: workshopRootDirectory
                    ).importCover(from: coverURL, anthologyID: targetID)
                    manifest.anthology.coverPath = coverPath
                    if previousFiles.contains(coverPath) == false {
                        newlyInstalledURLs.append(
                            anthologyDirectory.appending(path: coverPath))
                    }
                }
                databaseChanges.append(
                    .anthology(
                        manifest,
                        disposition: disposition))
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
        try validateFetchedRevisions(in: databaseChanges)
        try beforeDatabaseCommit()
        try syncDAO.applyFetchedChanges(
            databaseChanges,
            cloudRecords: cloudReceipts,
            deletedRecordNames: deletions.map(\.recordID.recordName))
        committed = true
    }

    private func validateFetchedRevisions(
        in changes: [ArticleFetchedDatabaseChange]
    ) throws {
        let fetchedCaptures = Dictionary(
            uniqueKeysWithValues: changes.compactMap {
                change
                    -> (String, ArticleCaptureRecord)? in
                guard case .capture(let capture) = change else { return nil }
                return (capture.id, capture)
            })
        let fetchedRevisions = changes.compactMap { change -> ArticleRevisionRecord? in
            guard case .revision(let revision) = change else { return nil }
            return revision
        }
        let fetchedRevisionsByID = Dictionary(
            uniqueKeysWithValues: fetchedRevisions.map { ($0.id, $0) })
        let fileStore = ArticleWorkshopFileStore(root: workshopRootDirectory)
        for revision in fetchedRevisions {
            if let existing = try syncDAO.revision(id: revision.id),
                existing != revision
            {
                throw ArticleCloudRecordCodec.Error.invalidField(
                    "revisionIdentityCollision")
            }
            let capture: ArticleCaptureRecord
            if let fetched = fetchedCaptures[revision.captureID] {
                capture = fetched
            } else if let stored = try syncDAO.capture(id: revision.captureID) {
                capture = stored
            } else {
                throw ArticleRevisionMaterializer.Error.revisionBelongsToAnotherCapture
            }
            if let parentID = revision.parentRevisionID {
                let parent: ArticleRevisionRecord?
                if let fetched = fetchedRevisionsByID[parentID] {
                    parent = fetched
                } else {
                    parent = try syncDAO.revision(id: parentID)
                }
                guard let parent else {
                    throw ArticleRevisionMaterializer.Error.malformedRevision
                }
                guard parent.captureID == revision.captureID else {
                    throw ArticleRevisionMaterializer.Error.revisionBelongsToAnotherCapture
                }
            }
            let source = try fileStore.loadSnapshot(for: capture)
            _ = try ArticleRevisionMaterializer().materialize(
                capture: capture,
                revision: revision,
                source: source)
        }
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
        let persistedChanges: [ArticlePendingCloudChange]
        do {
            persistedChanges = try changes.map { try syncDAO.enqueueReturning($0) }
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
        await driver.schedule(persistedChanges)
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
}

private actor ArticleCloudKitSyncEngineDriver: ArticleSyncEngineDriver, CKSyncEngineDelegate {
    private static let containerIdentifier = "iCloud.com.echo.audiobooks"

    private let syncDAO: ArticleSyncDAO
    private let codec: ArticleCloudRecordCodec
    private let batchApplier: ArticleFetchedCloudBatchApplier
    private let accountEventHandler: ArticleSyncAccountEventHandler
    private var engine: CKSyncEngine?
    private var stagedAssets: [String: [URL]] = [:]
    private var inFlightChanges: [String: ArticlePendingCloudChange] = [:]
    private var fetchProgress = ArticleSyncFetchProgress()

    init(syncDAO: ArticleSyncDAO, codec: ArticleCloudRecordCodec) {
        self.syncDAO = syncDAO
        self.codec = codec
        self.batchApplier = ArticleFetchedCloudBatchApplier(
            syncDAO: syncDAO,
            codec: codec)
        self.accountEventHandler = ArticleSyncAccountEventHandler(syncDAO: syncDAO)
    }

    func start() throws {
        guard engine == nil else { return }
        let restricted =
            try syncDAO.activeAccountOwnerIsQuarantined()
            || syncDAO.state()?.accountStatus == .restricted
        let storedState = restricted ? nil : try syncDAO.engineState()
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerIdentifier)
                .privateCloudDatabase,
            stateSerialization: storedState,
            delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        fetchProgress.resetForNewEngineEpoch()
        if restricted == false {
            engine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: zoneID))
            ])
            let changes = try syncDAO.pendingChanges()
            engine.state.add(
                pendingRecordZoneChanges: changes.map(pendingEngineChange))
        }
    }

    func schedule(_ changes: [ArticlePendingCloudChange]) async {
        guard let engine else { return }
        engine.state.add(
            pendingRecordZoneChanges: changes.map(pendingEngineChange))
    }

    func fetchChanges() async throws {
        guard let engine else { throw ArticleSyncEngineError.notStarted }
        try await engine.fetchChanges()
        do {
            try fetchProgress.throwIfFailed()
        } catch {
            await engine.cancelOperations()
            cleanupAllStagedAssets()
            self.engine = nil
            // Reconstruct from the last durable serialization. The failed
            // engine epoch is never allowed to publish a later checkpoint.
            try start()
            throw error
        }
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
            if fetchProgress.shouldPersistState {
                persistState(update.stateSerialization)
            }
        case .accountChange(let change):
            handleAccountChange(change, syncEngine: syncEngine)
        case .fetchedDatabaseChanges(let changes):
            handleFetchedDatabaseChanges(changes, syncEngine: syncEngine)
        case .fetchedRecordZoneChanges(let changes):
            handleFetchedRecordZoneChanges(changes)
        case .sentDatabaseChanges(let changes):
            handleSentDatabaseChanges(changes)
        case .sentRecordZoneChanges(let changes):
            handleSentRecordZoneChanges(changes, syncEngine: syncEngine)
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
        if let durable = try? syncDAO.pendingChanges() {
            for change in durable
            where context.options.scope.contains(pendingEngineChange(change)) {
                inFlightChanges[change.recordName] = change
            }
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
            let baseSystemFields =
                try syncDAO.cloudRecord(recordName: recordID.recordName)?.systemFields
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
                        isDirectory: true),
                    baseSystemFields: baseSystemFields)
            case .revision:
                guard let revision = try syncDAO.revision(id: change.entityID) else {
                    return nil
                }
                record = try codec.revisionRecord(
                    revision,
                    baseSystemFields: baseSystemFields)
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
                record = try codec.anthologyRecord(
                    manifest,
                    coverURL: coverURL,
                    baseSystemFields: baseSystemFields)
            }
            stagedAssets[recordID.recordName] = record.allKeys().compactMap {
                (record[$0] as? CKAsset)?.fileURL
            }
            inFlightChanges[recordID.recordName] = change
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

    private func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange,
        syncEngine: CKSyncEngine
    ) {
        do {
            cleanupAllStagedAssets()
            inFlightChanges.removeAll()
            if ArticleSyncAccountEventPolicy.startsNewEngineEpoch(event.changeType) {
                fetchProgress.resetForNewEngineEpoch()
            } else {
                fetchProgress.recordApplyFailure(.authentication)
            }
            let result = try accountEventHandler.handle(
                event.changeType,
                updatedAt: Date().ISO8601Format())
            if result.shouldSchedulePendingChanges {
                let changes = try syncDAO.pendingChanges()
                syncEngine.state.add(
                    pendingRecordZoneChanges: changes.map(pendingEngineChange))
            } else if ArticleSyncAccountEventPolicy.startsNewEngineEpoch(
                event.changeType)
            {
                fetchProgress.recordApplyFailure(.authentication)
            }
        } catch {
            // Local workshop data is deliberately preserved even when its sync
            // status receipt cannot be updated.
        }
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        let workshopDeletions = event.deletions.filter { $0.zoneID == zoneID }
        let result = ArticleSyncZoneRecoveryHandler(syncDAO: syncDAO).handle(
            deletionReasons: workshopDeletions.map(\.reason),
            updatedAt: Date().ISO8601Format(),
            fetchProgress: &fetchProgress)
        switch result {
        case .noAction:
            return
        case .quarantine:
            quarantineActiveLane(syncEngine: syncEngine)
        case .rebuild(let changes):
            syncEngine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: zoneID))
            ])
            syncEngine.state.add(
                pendingRecordZoneChanges: changes.map(pendingEngineChange))
            persist(stableCode: .missingZone)
        case .failed(let code):
            persist(stableCode: code)
        }
    }

    private func quarantineActiveLane(syncEngine: CKSyncEngine) {
        let recordChanges = syncEngine.state.pendingRecordZoneChanges
        let databaseChanges = syncEngine.state.pendingDatabaseChanges
        syncEngine.state.remove(pendingRecordZoneChanges: recordChanges)
        syncEngine.state.remove(pendingDatabaseChanges: databaseChanges)
        cleanupAllStagedAssets()
        inFlightChanges.removeAll()
        fetchProgress.recordApplyFailure(.authentication)
        do {
            try syncDAO.quarantineActiveAccountOwner(
                reason: "zoneResetOrPurge",
                updatedAt: Date().ISO8601Format())
        } catch {
            persist(stableCode: .localPersistence)
        }
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
            fetchProgress.recordApplySuccess()
        } catch {
            fetchProgress.recordApplyFailure(.invalidRemoteRecord)
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
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        do {
            let saved = try event.savedRecords.compactMap {
                record
                    -> ArticleCloudSaveAcknowledgement? in
                let name = record.recordID.recordName
                guard let change = inFlightChanges.removeValue(forKey: name) else {
                    return nil
                }
                return ArticleCloudSaveAcknowledgement(
                    recordName: name,
                    generation: change.generation,
                    systemFields: try codec.systemFields(for: record),
                    contentFingerprint: try codec.contentFingerprint(for: record))
            }
            let deleted = event.deletedRecordIDs.compactMap {
                recordID
                    -> ArticleCloudDeleteAcknowledgement? in
                guard
                    let change = inFlightChanges.removeValue(
                        forKey: recordID.recordName)
                else {
                    return nil
                }
                return ArticleCloudDeleteAcknowledgement(
                    recordName: recordID.recordName,
                    generation: change.generation)
            }
            try syncDAO.acknowledgeSaved(saved)
            try syncDAO.acknowledgeDeleted(deleted)
        } catch {
            persist(stableCode: .localPersistence)
        }
        for name in event.savedRecords.map(\.recordID.recordName)
            + event.deletedRecordIDs.map(\.recordName)
        {
            cleanupStagedAssets(recordName: name)
        }

        for failure in event.failedRecordSaves {
            handleFailedSave(failure, syncEngine: syncEngine)
        }
        for (recordID, error) in event.failedRecordDeletes {
            handleFailedDelete(
                recordID: recordID,
                error: error,
                syncEngine: syncEngine)
        }
        let failures =
            event.failedRecordSaves.map(\.error)
            + Array(event.failedRecordDeletes.values)
        if failures.isEmpty == false {
            let code: ArticleSyncFailureCode =
                failures.count > 1 ? .partialFailure : .classify(failures[0])
            persist(stableCode: code)
        }
    }

    private func handleFailedSave(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) {
        let recordName = failure.record.recordID.recordName
        let userResetEncryptedData =
            failure.error.code == .zoneNotFound
            && (failure.error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?
                .boolValue == true
        let plan = ArticleSyncFailedChangePlan.make(
            code: failure.error.code,
            change: inFlightChanges[recordName]
                ?? (try? syncDAO.pendingChange(recordName: recordName)))
        let action: ArticleSyncFailureAction =
            userResetEncryptedData
            ? .quarantineLane
            : plan.action
        switch action {
        case .mergeServerAndRequeue:
            guard let serverRecord = failure.error.serverRecord else {
                persist(stableCode: .serverRecordConflict)
                return
            }
            do {
                if let pending = try syncDAO.pendingChange(recordName: recordName),
                    pending.recordType != .anthology,
                    try codec.contentFingerprint(for: failure.record)
                        != codec.contentFingerprint(for: serverRecord)
                {
                    // Captures and revisions are immutable identities. A server
                    // record with different content is parked for review rather
                    // than being overwritten under the same deterministic ID.
                    persist(stableCode: .serverRecordConflict)
                    cleanupStagedAssets(recordName: recordName)
                    return
                }
                try batchApplier.apply(
                    modifications: [serverRecord],
                    deletions: [])
                if let pending = try syncDAO.pendingChange(recordName: recordName) {
                    syncEngine.state.add(
                        pendingRecordZoneChanges: [pendingEngineChange(pending)])
                }
                inFlightChanges.removeValue(forKey: recordName)
            } catch {
                persist(stableCode: .invalidRemoteRecord)
            }
        case .rebuildZone:
            do {
                let changes = try syncDAO.recoverMissingZone(
                    updatedAt: Date().ISO8601Format())
                syncEngine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: zoneID))
                ])
                syncEngine.state.add(
                    pendingRecordZoneChanges: changes.map(pendingEngineChange))
                inFlightChanges.removeValue(forKey: recordName)
            } catch {
                persist(stableCode: .localPersistence)
            }
        case .engineRetains, .waitForUser:
            break
        case .manualRequeue:
            if let pending = plan.changeToRequeue {
                syncEngine.state.add(
                    pendingRecordZoneChanges: [pendingEngineChange(pending)])
            }
        case .quarantineLane:
            quarantineActiveLane(syncEngine: syncEngine)
        case .acknowledgeMissingDelete:
            break
        }
        cleanupStagedAssets(recordName: recordName)
    }

    private func handleFailedDelete(
        recordID: CKRecord.ID,
        error: CKError,
        syncEngine: CKSyncEngine
    ) {
        let recordName = recordID.recordName
        let plan = ArticleSyncFailedChangePlan.make(
            code: error.code,
            change: inFlightChanges[recordName]
                ?? (try? syncDAO.pendingChange(recordName: recordName)))
        let action = plan.action
        switch action {
        case .acknowledgeMissingDelete:
            guard let acknowledgement = plan.deleteToAcknowledge else {
                return
            }
            inFlightChanges.removeValue(forKey: recordName)
            do {
                try syncDAO.acknowledgeDeleted([acknowledgement])
            } catch {
                persist(stableCode: .localPersistence)
            }
        case .rebuildZone:
            // A failed delete whose zone is absent already satisfies the
            // requested final state and is handled above, never by recreation.
            break
        case .engineRetains, .waitForUser:
            break
        case .manualRequeue:
            if let pending = plan.changeToRequeue {
                syncEngine.state.add(
                    pendingRecordZoneChanges: [pendingEngineChange(pending)])
            }
        case .quarantineLane:
            quarantineActiveLane(syncEngine: syncEngine)
        case .mergeServerAndRequeue:
            break
        }
        _ = syncEngine
        cleanupStagedAssets(recordName: recordName)
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
