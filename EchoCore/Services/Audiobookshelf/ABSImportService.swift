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
        // Start clean so a retry never mixes a previous partial extraction.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let zipURL = folder.appendingPathComponent("__abs_download.zip")
            try await service.downloadItemZip(itemID: item.id, to: zipURL)
            try FileManager.default.unzipItem(at: zipURL, to: folder)
            try? FileManager.default.removeItem(at: zipURL)
        } catch {
            try? FileManager.default.removeItem(at: folder)  // never leave a partial folder
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
            topicsJSON: Self.encodeTopics(item.topics)
        )
        try AudiobookDAO(db: db.writer).save(record)
        return folder
    }

    static func encodeTopics(_ topics: [String]) -> String? {
        guard !topics.isEmpty, let data = try? JSONEncoder().encode(topics) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
