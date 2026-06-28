// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ZIPFoundation

/// Orchestrates importing one Audiobookshelf item into Echo's local pipeline:
/// download the whole-item zip → unzip into the managed folder → stamp the audiobook
/// row with ABS provenance + the real title/author. Returns the folder URL; the caller
/// hands it to `loadFolder` (which discovers tracks + the sibling EPUB unchanged).
/// Concrete `@MainActor final class`, constructor-injected (no protocol).
@MainActor
final class ABSImportService {
    private let service: AudiobookshelfService
    private let db: DatabaseService
    private let serverID: String

    init(service: AudiobookshelfService, db: DatabaseService, serverID: String) {
        self.service = service
        self.db = db
        self.serverID = serverID
    }

    /// Download + unzip + pre-stamp. Returns the managed folder to hand to `loadFolder`.
    @discardableResult
    func prepareLocalFolder(for item: ABSLibraryItem) async throws -> URL {
        let folder = FileLocations.absLibraryDirectory(remoteItemID: item.id)
        let stagingFolder = FileLocations.absImportStagingDirectory(remoteItemID: item.id)
        try? FileManager.default.removeItem(at: stagingFolder)
        try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingFolder) }

        let coverArtPath: String?
        do {
            let zipURL = stagingFolder.appendingPathComponent("__abs_download.zip")
            try await service.downloadItemZip(itemID: item.id, to: zipURL)
            try await Self.extractWholeAudiobookArchive(zipURL: zipURL, to: stagingFolder)
            try? FileManager.default.removeItem(at: zipURL)
            try Self.validatePreparedFolder(stagingFolder)
            coverArtPath = try await downloadCoverIfAvailable(
                for: item,
                into: stagingFolder,
                finalAudiobookID: folder.absoluteString)
        } catch {
            throw error
        }

        // Pre-stamp BEFORE loadFolder so persistAudiobook's carry-over preserves these.
        let record = AudiobookRecord(
            id: folder.absoluteString,
            title: item.title ?? "Untitled",
            author: item.author,
            duration: item.duration ?? 0,
            fileCount: nil,
            addedAt: Date().ISO8601Format(),
            sourceType: "audiobookshelf",
            serverID: serverID,
            remoteItemID: item.id,
            topicsJSON: Self.encodeTopics(item.topics),
            coverArtPath: coverArtPath
        )
        try commitPreparedFolder(stagingFolder, to: folder, record: record)
        return folder
    }

    static func encodeTopics(_ topics: [String]) -> String? {
        guard !topics.isEmpty, let data = try? JSONEncoder().encode(topics) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func downloadCoverIfAvailable(
        for item: ABSLibraryItem,
        into folder: URL,
        finalAudiobookID: String
    ) async -> String? {
        guard item.coverPath != nil else { return nil }
        do {
            let data = try await service.coverImageData(itemID: item.id)
            try data.write(to: folder.appending(path: "cover.jpg"), options: .atomic)
            return try Self.writeLibraryCover(data, audiobookID: finalAudiobookID)
        } catch {
            return nil
        }
    }

    private static func writeLibraryCover(_ data: Data, audiobookID: String) throws -> String {
        try FileManager.default.createDirectory(
            at: FileLocations.libraryCoversDirectory,
            withIntermediateDirectories: true)
        let filename = URL(fileURLWithPath: audiobookID).sha256Hash + ".jpg"
        let url = FileLocations.libraryCoversDirectory.appending(path: filename)
        try data.write(to: url, options: .atomic)
        return filename
    }

    private func commitPreparedFolder(
        _ stagingFolder: URL,
        to finalFolder: URL,
        record: AudiobookRecord
    ) throws {
        let fileManager = FileManager.default
        let parent = finalFolder.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        // Existing folder replacement is atomic at the filesystem level: readers see the
        // old completed directory or the new completed directory, never an empty gap.
        let backupFolder = parent.appending(
            path: ".\(finalFolder.lastPathComponent)-backup-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        let replacedExistingFolder = fileManager.fileExists(atPath: finalFolder.path)
        var publishedNewFolder = false

        do {
            if replacedExistingFolder {
                try replaceExistingFolder(
                    finalFolder,
                    with: stagingFolder,
                    backupFolder: backupFolder,
                    fileManager: fileManager)
            } else {
                try fileManager.moveItem(at: stagingFolder, to: finalFolder)
                publishedNewFolder = true
            }
            try AudiobookDAO(db: db.writer).save(record)
            if replacedExistingFolder {
                try? fileManager.removeItem(at: backupFolder)
            }
        } catch {
            if replacedExistingFolder {
                try? restoreExistingFolder(
                    from: backupFolder,
                    to: finalFolder,
                    fileManager: fileManager)
                try? fileManager.removeItem(at: backupFolder)
            } else if publishedNewFolder {
                try? fileManager.removeItem(at: finalFolder)
            }
            throw error
        }
    }

    private func replaceExistingFolder(
        _ finalFolder: URL,
        with stagingFolder: URL,
        backupFolder: URL,
        fileManager: FileManager
    ) throws {
        try? fileManager.removeItem(at: backupFolder)
        var resultingURL: NSURL?
        try fileManager.replaceItem(
            at: finalFolder,
            withItemAt: stagingFolder,
            backupItemName: backupFolder.lastPathComponent,
            options: [.withoutDeletingBackupItem],
            resultingItemURL: &resultingURL)
    }

    private func restoreExistingFolder(
        from backupFolder: URL,
        to finalFolder: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: backupFolder.path) else { return }
        var resultingURL: NSURL?
        try fileManager.replaceItem(
            at: finalFolder,
            withItemAt: backupFolder,
            backupItemName: nil,
            options: [],
            resultingItemURL: &resultingURL)
    }

    @concurrent
    nonisolated private static func extractWholeAudiobookArchive(zipURL: URL, to destination: URL)
        async throws
    {
        let archive = try Archive(url: zipURL, accessMode: .read)
        var totalExtracted: UInt64 = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            totalExtracted = try ArchiveExtractionLimits.checkedTotal(
                addingEntryOfSize: entry.uncompressedSize,
                to: totalExtracted,
                budget: .absWholeAudiobook)
            let output = try safeDestination(for: entry.path, within: destination)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: output)
        }
    }

    nonisolated private static func safeDestination(for entryPath: String, within root: URL) throws
        -> URL
    {
        guard !entryPath.hasPrefix("/") else {
            throw Archive.ArchiveError.invalidEntryPath
        }

        let destination = root.appendingPathComponent(entryPath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard destination.path == rootPath || destination.path.hasPrefix(rootPath + "/") else {
            throw Archive.ArchiveError.invalidEntryPath
        }

        return destination
    }

    private static func validatePreparedFolder(_ folder: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }

        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return
            }
        }

        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: folder.path])
    }
}
