// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ABSDownloadProgress: Equatable, Sendable {
    let bytesReceived: Int64
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

enum ABSImportStage: String, Equatable, Sendable {
    case downloading
    case extracting
    case validating
    case addingToEcho
    case added
}

struct ABSImportProgress: Equatable, Sendable {
    let stage: ABSImportStage
    let completedUnits: Int64
    let totalUnits: Int64?
}

struct ABSImportFailure: LocalizedError, Equatable, Sendable {
    let stage: ABSImportStage
    let message: String
    let isRetryable: Bool

    var errorDescription: String? { message }
}

struct ABSImportedBook: Identifiable, Equatable, Sendable {
    let remoteItemID: String
    let folderURL: URL
    let title: String

    var id: String { remoteItemID }
}

enum ABSLocalImportStatus {
    /// True when the managed folder contains audio or a study document at its root.
    /// This deliberately matches the player's direct-child folder scan: content nested
    /// under an archive subdirectory is not locally usable until the import is repaired.
    nonisolated static func hasSupportedRootContent(at folderURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }

        return urls.contains { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return false
            }

            let fileExtension = url.pathExtension.lowercased()
            return PlaylistManager.audioExtensions.contains(fileExtension)
                || PlaylistManager.documentExtensions.contains(fileExtension)
        }
    }

    nonisolated static func usableBooks(records: [AudiobookRecord]) -> [ABSImportedBook] {
        records.compactMap { record in
            guard let remoteItemID = record.remoteItemID else { return nil }

            let folderURL = folderURL(forRecordID: record.id)
            guard hasSupportedRootContent(at: folderURL) else { return nil }

            return ABSImportedBook(
                remoteItemID: remoteItemID,
                folderURL: folderURL,
                title: record.title
            )
        }
    }

    private nonisolated static func folderURL(forRecordID recordID: String) -> URL {
        if let url = URL(string: recordID), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: recordID)
    }
}
