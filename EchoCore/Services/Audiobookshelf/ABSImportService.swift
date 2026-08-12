// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import OSLog
import ZIPFoundation

/// Downloads, validates, atomically publishes, and verifies an Audiobookshelf item.
@MainActor
final class ABSImportService {
    private nonisolated static let importLogger = Logger(category: "AudiobookshelfImport")
    private let service: AudiobookshelfService
    private let databaseWriter: DatabaseWriter
    private let serverID: String
    private let afterExtractedEntry: @Sendable () async -> Void
    private let afterPersistence: @Sendable () async -> Void
    private let beforeRestoreExistingFolder: @Sendable () throws -> Void
    private let beforeRemoveNewFolder: @Sendable () throws -> Void

    init(
        service: AudiobookshelfService,
        db: DatabaseService,
        serverID: String,
        afterExtractedEntry: @escaping @Sendable () async -> Void = {},
        afterPersistence: @escaping @Sendable () async -> Void = {},
        beforeRestoreExistingFolder: @escaping @Sendable () throws -> Void = {},
        beforeRemoveNewFolder: @escaping @Sendable () throws -> Void = {}
    ) {
        self.service = service
        self.databaseWriter = db.writer
        self.serverID = serverID
        self.afterExtractedEntry = afterExtractedEntry
        self.afterPersistence = afterPersistence
        self.beforeRestoreExistingFolder = beforeRestoreExistingFolder
        self.beforeRemoveNewFolder = beforeRemoveNewFolder
    }

    @discardableResult
    func prepareLocalFolder(
        for item: ABSLibraryItem,
        onProgress: @escaping @MainActor @Sendable (ABSImportProgress) -> Void = { _ in }
    ) async throws -> ABSImportedBook {
        let finalFolder = FileLocations.absLibraryDirectory(remoteItemID: item.id)
        let stagingFolder = FileLocations.absImportStagingDirectory(remoteItemID: item.id)
        let zipURL = stagingFolder.appending(path: "__abs_download.zip")
        let identifier = Self.hashedIdentifier(serverID: serverID, remoteItemID: item.id)
        let hadExistingUsableCopy = await Self.hasSupportedContent(finalFolder)
        var currentStage = ABSImportStage.downloading

        do {
            try await Self.prepareStagingFolder(stagingFolder)
            try Task.checkCancellation()
            report(
                ABSImportProgress(stage: .downloading, completedUnits: 0, totalUnits: nil),
                identifier: identifier,
                onProgress: onProgress)
            try await service.downloadItemZip(itemID: item.id, to: zipURL) { [weak self] update in
                self?.report(
                    ABSImportProgress(
                        stage: .downloading,
                        completedUnits: update.bytesReceived,
                        totalUnits: update.totalBytes),
                    identifier: identifier,
                    onProgress: onProgress)
            }

            currentStage = .extracting
            try await Self.extractWholeAudiobookArchive(
                zipURL: zipURL,
                to: stagingFolder,
                identifier: identifier,
                afterExtractedEntry: afterExtractedEntry,
                onProgress: onProgress)
            try await Self.removeItemIfPresent(zipURL)

            currentStage = .validating
            report(
                ABSImportProgress(stage: .validating, completedUnits: 0, totalUnits: nil),
                identifier: identifier,
                onProgress: onProgress)
            try await Self.validatePreparedFolder(stagingFolder)

            let coverArtPath = await downloadCoverIfAvailable(
                for: item,
                into: stagingFolder,
                finalAudiobookID: finalFolder.absoluteString)
            let record = AudiobookRecord(
                id: finalFolder.absoluteString,
                title: item.title ?? "Untitled",
                author: item.author,
                duration: item.duration ?? 0,
                fileCount: nil,
                addedAt: Date().ISO8601Format(),
                sourceType: "audiobookshelf",
                serverID: serverID,
                remoteItemID: item.id,
                topicsJSON: Self.encodeTopics(item.topics),
                coverArtPath: coverArtPath)

            currentStage = .addingToEcho
            report(
                ABSImportProgress(stage: .addingToEcho, completedUnits: 0, totalUnits: nil),
                identifier: identifier,
                onProgress: onProgress)
            let importedBook = try await Self.commitAndVerifyPreparedFolder(
                stagingFolder,
                to: finalFolder,
                record: record,
                serverID: serverID,
                remoteItemID: item.id,
                databaseWriter: databaseWriter,
                identifier: identifier,
                afterPersistence: afterPersistence,
                beforeRestoreExistingFolder: beforeRestoreExistingFolder,
                beforeRemoveNewFolder: beforeRemoveNewFolder)

            currentStage = .added
            report(
                ABSImportProgress(stage: .added, completedUnits: 1, totalUnits: 1),
                identifier: identifier,
                onProgress: onProgress)
            return importedBook
        } catch {
            await Self.cleanupItemIfPresent(stagingFolder)
            if error is CancellationError || Task.isCancelled {
                Self.importLogger.notice(
                    "ABS import cancelled stage=\(currentStage.rawValue, privacy: .public) id=\(identifier, privacy: .private)"
                )
                throw CancellationError()
            }
            let failure = Self.failure(
                for: error,
                at: currentStage,
                preservedExistingCopy: hadExistingUsableCopy)
            Self.importLogger.error(
                "ABS import failed stage=\(failure.stage.rawValue, privacy: .public) id=\(identifier, privacy: .private) category=\(Self.errorCategory(error), privacy: .public)"
            )
            throw failure
        }
    }

    nonisolated static func encodeTopics(_ topics: [String]) -> String? {
        guard !topics.isEmpty, let data = try? JSONEncoder().encode(topics) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func report(
        _ progress: ABSImportProgress,
        identifier: String,
        onProgress: @escaping @MainActor @Sendable (ABSImportProgress) -> Void
    ) {
        onProgress(progress)
        log(progress, identifier: identifier)
    }

    private func log(_ progress: ABSImportProgress, identifier: String) {
        Self.importLogger.info(
            "ABS import stage=\(progress.stage.rawValue, privacy: .public) id=\(identifier, privacy: .private) units=\(progress.completedUnits, privacy: .public) totalKnown=\(progress.totalUnits != nil, privacy: .public) total=\(progress.totalUnits ?? 0, privacy: .public)"
        )
    }

    private func downloadCoverIfAvailable(
        for item: ABSLibraryItem,
        into folder: URL,
        finalAudiobookID: String
    ) async -> String? {
        guard item.coverPath != nil else { return nil }
        do {
            let data = try await service.coverImageData(itemID: item.id)
            return try await Self.writeStagedCover(
                data,
                into: folder,
                finalAudiobookID: finalAudiobookID)
        } catch {
            return nil
        }
    }

    @concurrent
    nonisolated private static func writeStagedCover(
        _ data: Data,
        into folder: URL,
        finalAudiobookID: String
    ) async throws -> String {
        try data.write(to: folder.appending(path: "cover.jpg"), options: .atomic)
        let filename = Self.sha256Hex(finalAudiobookID) + ".jpg"
        return filename
    }

    @concurrent
    nonisolated private static func prepareStagingFolder(_ folder: URL) async throws {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @concurrent
    nonisolated private static func removeItemIfPresent(_ url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @concurrent
    nonisolated private static func cleanupItemIfPresent(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    @concurrent
    nonisolated private static func hasSupportedContent(_ url: URL) async -> Bool {
        ABSLocalImportStatus.hasSupportedRootContent(at: url)
    }

    @concurrent
    nonisolated private static func extractWholeAudiobookArchive(
        zipURL: URL,
        to destination: URL,
        identifier: String,
        afterExtractedEntry: @escaping @Sendable () async -> Void,
        onProgress: @escaping @MainActor @Sendable (ABSImportProgress) -> Void
    ) async throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        var totalBytes: UInt64 = 0
        var fileCount = 0
        for entry in archive where entry.type == .file {
            try Task.checkCancellation()
            totalBytes = try ArchiveExtractionLimits.checkedTotal(
                addingEntryOfSize: entry.uncompressedSize,
                to: totalBytes,
                budget: .absWholeAudiobook)
            fileCount += 1
        }

        let usesBytes = totalBytes > 0
        let totalUnits = usesBytes ? Int64(clamping: totalBytes) : Int64(fileCount)
        let startingProgress = ABSImportProgress(
            stage: .extracting, completedUnits: 0, totalUnits: totalUnits)
        await onProgress(startingProgress)
        logExtraction(startingProgress, identifier: identifier)

        var completedBytes: UInt64 = 0
        var completedFiles = 0
        for entry in archive where entry.type == .file {
            try Task.checkCancellation()
            let output = try safeDestination(for: entry.path, within: destination)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: output)
            completedBytes += entry.uncompressedSize
            completedFiles += 1
            await afterExtractedEntry()
            try Task.checkCancellation()
            let progress = ABSImportProgress(
                stage: .extracting,
                completedUnits: usesBytes
                    ? Int64(clamping: completedBytes) : Int64(completedFiles),
                totalUnits: totalUnits)
            await onProgress(progress)
            logExtraction(progress, identifier: identifier)
            await Task.yield()
            try Task.checkCancellation()
        }
    }

    nonisolated private static func logExtraction(
        _ progress: ABSImportProgress,
        identifier: String
    ) {
        importLogger.info(
            "ABS import stage=extracting id=\(identifier, privacy: .private) units=\(progress.completedUnits, privacy: .public) totalKnown=\(progress.totalUnits != nil, privacy: .public) total=\(progress.totalUnits ?? 0, privacy: .public)"
        )
    }

    nonisolated private static func safeDestination(for entryPath: String, within root: URL) throws
        -> URL
    {
        guard !entryPath.hasPrefix("/") else { throw Archive.ArchiveError.invalidEntryPath }
        let destination = root.appendingPathComponent(entryPath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard destination.path == rootPath || destination.path.hasPrefix(rootPath + "/") else {
            throw Archive.ArchiveError.invalidEntryPath
        }
        return destination
    }

    @concurrent
    nonisolated private static func validatePreparedFolder(_ folder: URL) async throws {
        try Task.checkCancellation()
        guard ABSLocalImportStatus.hasSupportedRootContent(at: folder) else {
            throw ABSPreparedFolderValidationError.noSupportedRootContent
        }
        try Task.checkCancellation()
    }

    @concurrent
    nonisolated private static func commitAndVerifyPreparedFolder(
        _ stagingFolder: URL,
        to finalFolder: URL,
        record: AudiobookRecord,
        serverID: String,
        remoteItemID: String,
        databaseWriter: DatabaseWriter,
        identifier: String,
        afterPersistence: @escaping @Sendable () async -> Void,
        beforeRestoreExistingFolder: @escaping @Sendable () throws -> Void,
        beforeRemoveNewFolder: @escaping @Sendable () throws -> Void
    ) async throws -> ABSImportedBook {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let parent = finalFolder.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let backupFolder = parent.appending(
            path: ".\(finalFolder.lastPathComponent)-backup-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        let replacedExistingFolder = fileManager.fileExists(atPath: finalFolder.path)
        var publishedNewFolder = false
        let previousRecord = try await databaseWriter.read { db in
            try AudiobookRecord.fetchOne(db, key: record.id)
        }
        let coverPublication = record.coverArtPath.map {
            LibraryCoverPublication(
                filename: $0,
                finalFolder: finalFolder)
        }
        var coverWasPublished = false
        var existingCoverWasReplaced = false

        do {
            if replacedExistingFolder {
                try? fileManager.removeItem(at: backupFolder)
                var resultingURL: NSURL?
                try fileManager.replaceItem(
                    at: finalFolder,
                    withItemAt: stagingFolder,
                    backupItemName: backupFolder.lastPathComponent,
                    options: [.withoutDeletingBackupItem],
                    resultingItemURL: &resultingURL)
            } else {
                try fileManager.moveItem(at: stagingFolder, to: finalFolder)
                publishedNewFolder = true
            }

            if let coverPublication,
                fileManager.fileExists(atPath: coverPublication.stagedSource.path)
            {
                (coverWasPublished, existingCoverWasReplaced) = try publishLibraryCover(
                    coverPublication,
                    fileManager: fileManager)
            }

            let importedBook = try await databaseWriter.write { db -> ABSImportedBook in
                var savedRecord = record
                try savedRecord.save(db)
                guard
                    let resolved = try AudiobookRecord.fetchOne(db, key: record.id),
                    resolved.sourceType == "audiobookshelf",
                    resolved.serverID == serverID,
                    resolved.remoteItemID == remoteItemID,
                    let book = ABSLocalImportStatus.usableBooks(records: [resolved]).first
                else {
                    throw ABSImportVerificationError.unresolvedProvenance
                }
                return book
            }
            await afterPersistence()
            let cancellationArrivedAfterPersistence = Task.isCancelled
            if replacedExistingFolder { try? fileManager.removeItem(at: backupFolder) }
            if existingCoverWasReplaced, let coverPublication {
                try? fileManager.removeItem(at: coverPublication.backup)
            }
            if let coverPublication { try? fileManager.removeItem(at: coverPublication.temporary) }
            if cancellationArrivedAfterPersistence {
                importLogger.notice(
                    "ABS import cancellation arrived after durable commit id=\(identifier, privacy: .private); returning committed success"
                )
            }
            return importedBook
        } catch {
            var rollbackFailed = false
            do {
                try await restoreRecord(
                    previousRecord,
                    recordID: record.id,
                    databaseWriter: databaseWriter)
            } catch {
                rollbackFailed = true
                logRollbackFailure(identifier: identifier, category: "database")
            }

            if let coverPublication, coverWasPublished {
                do {
                    try rollbackLibraryCover(
                        coverPublication,
                        replacedExisting: existingCoverWasReplaced,
                        fileManager: fileManager)
                } catch {
                    rollbackFailed = true
                    logRollbackFailure(identifier: identifier, category: "cover")
                }
            }

            if replacedExistingFolder {
                do {
                    try beforeRestoreExistingFolder()
                    guard fileManager.fileExists(atPath: backupFolder.path) else {
                        throw ABSImportRollbackError.recoveryIncomplete
                    }
                    var resultingURL: NSURL?
                    try fileManager.replaceItem(
                        at: finalFolder,
                        withItemAt: backupFolder,
                        backupItemName: nil,
                        options: [],
                        resultingItemURL: &resultingURL)
                    guard ABSLocalImportStatus.hasSupportedRootContent(at: finalFolder) else {
                        throw ABSImportRollbackError.recoveryIncomplete
                    }
                    try? fileManager.removeItem(at: backupFolder)
                } catch {
                    rollbackFailed = true
                    logRollbackFailure(identifier: identifier, category: "folder")
                }
            } else if publishedNewFolder {
                do {
                    try beforeRemoveNewFolder()
                    try fileManager.removeItem(at: finalFolder)
                    guard !fileManager.fileExists(atPath: finalFolder.path) else {
                        throw ABSImportRollbackError.recoveryIncomplete
                    }
                } catch {
                    rollbackFailed = true
                    logRollbackFailure(identifier: identifier, category: "folder")
                }
            }
            if rollbackFailed { throw ABSImportRollbackError.recoveryIncomplete }
            throw error
        }
    }

    nonisolated private static func publishLibraryCover(
        _ publication: LibraryCoverPublication,
        fileManager: FileManager
    ) throws -> (published: Bool, replacedExisting: Bool) {
        try fileManager.createDirectory(
            at: publication.final.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? fileManager.removeItem(at: publication.temporary)
        try? fileManager.removeItem(at: publication.backup)
        try fileManager.copyItem(at: publication.stagedSource, to: publication.temporary)
        if fileManager.fileExists(atPath: publication.final.path) {
            var resultingURL: NSURL?
            try fileManager.replaceItem(
                at: publication.final,
                withItemAt: publication.temporary,
                backupItemName: publication.backup.lastPathComponent,
                options: [.withoutDeletingBackupItem],
                resultingItemURL: &resultingURL)
            return (true, true)
        }
        try fileManager.moveItem(at: publication.temporary, to: publication.final)
        return (true, false)
    }

    nonisolated private static func rollbackLibraryCover(
        _ publication: LibraryCoverPublication,
        replacedExisting: Bool,
        fileManager: FileManager
    ) throws {
        defer { try? fileManager.removeItem(at: publication.temporary) }
        if replacedExisting {
            guard fileManager.fileExists(atPath: publication.backup.path) else {
                throw ABSImportRollbackError.recoveryIncomplete
            }
            var resultingURL: NSURL?
            try fileManager.replaceItem(
                at: publication.final,
                withItemAt: publication.backup,
                backupItemName: nil,
                options: [],
                resultingItemURL: &resultingURL)
            guard fileManager.fileExists(atPath: publication.final.path) else {
                throw ABSImportRollbackError.recoveryIncomplete
            }
            try? fileManager.removeItem(at: publication.backup)
        } else {
            try fileManager.removeItem(at: publication.final)
        }
    }

    nonisolated private static func logRollbackFailure(identifier: String, category: String) {
        importLogger.error(
            "ABS import rollback incomplete id=\(identifier, privacy: .private) category=\(category, privacy: .public); recoverable backup retained when available"
        )
    }

    nonisolated private static func restoreRecord(
        _ previousRecord: AudiobookRecord?,
        recordID: String,
        databaseWriter: DatabaseWriter
    ) async throws {
        try await databaseWriter.write { db in
            if var previousRecord {
                try previousRecord.save(db)
            } else {
                _ = try AudiobookRecord.deleteOne(db, key: recordID)
            }
        }
    }

    nonisolated private static func hashedIdentifier(serverID: String, remoteItemID: String)
        -> String
    {
        SHA256.hash(data: Data("\(serverID):\(remoteItemID)".utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func failure(
        for error: Error,
        at stage: ABSImportStage,
        preservedExistingCopy: Bool
    )
        -> ABSImportFailure
    {
        if error is ABSImportRollbackError {
            return ABSImportFailure(
                stage: .addingToEcho,
                message: String(
                    localized:
                        "Echo could not complete automatic recovery. A recoverable import copy was retained."
                ),
                isRetryable: false)
        }
        if let failure = error as? ABSImportFailure { return failure }
        switch stage {
        case .downloading:
            return ABSImportFailure(
                stage: stage,
                message: String(
                    localized:
                        "The audiobook download failed. Check the connection and try again."),
                isRetryable: true)
        case .extracting:
            return ABSImportFailure(
                stage: stage,
                message: String(
                    localized: "Echo could not unpack this audiobook. Download it again and retry."),
                isRetryable: true)
        case .validating:
            return ABSImportFailure(
                stage: stage,
                message: String(
                    localized:
                        "The download does not contain supported audio or a study document at its top level."
                ),
                isRetryable: false)
        case .addingToEcho, .added:
            return ABSImportFailure(
                stage: .addingToEcho,
                message: preservedExistingCopy
                    ? String(
                        localized:
                            "Echo could not finish updating this audiobook. Your previous copy was preserved."
                    )
                    : String(
                        localized:
                            "Echo could not finish adding this audiobook. No partial copy was kept."
                    ),
                isRetryable: true)
        }
    }

    nonisolated private static func errorCategory(_ error: Error) -> String {
        if let absError = error as? ABSError { return absError.privacySafeLogDescription }
        if error is ArchiveExtractionLimits.LimitError { return "archive limit" }
        if error is Archive.ArchiveError { return "archive" }
        if error is ABSPreparedFolderValidationError { return "unsupported content" }
        if error is ABSImportVerificationError { return "verification" }
        if error is ABSImportRollbackError { return "rollback" }
        if error is CancellationError { return "cancelled" }
        if error is GRDB.DatabaseError { return "database" }
        if error is CocoaError { return "filesystem" }
        return "local"
    }
}

private nonisolated enum ABSPreparedFolderValidationError: Error {
    case noSupportedRootContent
}

private nonisolated enum ABSImportVerificationError: Error {
    case unresolvedProvenance
}

private nonisolated enum ABSImportRollbackError: Error {
    case recoveryIncomplete
}

private nonisolated struct LibraryCoverPublication: Sendable {
    let final: URL
    let stagedSource: URL
    let temporary: URL
    let backup: URL

    init(filename: String, finalFolder: URL) {
        final = FileLocations.libraryCoversDirectory.appending(path: filename)
        stagedSource = finalFolder.appending(path: "cover.jpg")
        temporary = FileLocations.libraryCoversDirectory.appending(
            path: ".\(filename)-import-\(UUID().uuidString)")
        backup = FileLocations.libraryCoversDirectory.appending(
            path: ".\(filename)-backup-\(UUID().uuidString)")
    }
}
