// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@MainActor
struct ArticleInboxIngestionService {
    enum Error: Swift.Error, LocalizedError {
        case conflictingExistingCapture(UUID)

        var errorDescription: String? {
            switch self {
            case .conflictingExistingCapture(let id):
                return "The existing article capture record for \(id.uuidString) has a different digest."
            }
        }
    }

    let captureDAO: ArticleCaptureDAO
    let fileStore: ArticleWorkshopFileStore
    let stagingRoot: URL

    init(
        captureDAO: ArticleCaptureDAO,
        fileStore: ArticleWorkshopFileStore = ArticleWorkshopFileStore(),
        stagingRoot: URL
    ) {
        self.captureDAO = captureDAO
        self.fileStore = fileStore
        self.stagingRoot = stagingRoot
    }

    func drainStaging() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stagingRoot.path) else { return }
        let packages = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for package in packages {
            let values = try package.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            guard fileManager.fileExists(atPath: package.appending(path: "complete").path) else { continue }

            let imported = try fileStore.importEnvelope(at: package)
            if let existing = try captureDAO.capture(id: imported.envelope.captureID.uuidString) {
                guard existing.contentSHA256 == imported.sha256 else {
                    throw Error.conflictingExistingCapture(imported.envelope.captureID)
                }
                try fileManager.removeItem(at: package)
                continue
            }

            try captureDAO.saveCapture(record(for: imported))
            try fileManager.removeItem(at: package)
        }
    }

    private func record(for imported: ArticleWorkshopFileStore.ImportedEnvelope) -> ArticleCaptureRecord {
        let envelope = imported.envelope
        let timestamp = envelope.capturedAt.ISO8601Format()
        return ArticleCaptureRecord(
            id: envelope.captureID.uuidString,
            sourceURL: envelope.payload.sourceURL,
            canonicalURL: envelope.payload.canonicalURL,
            title: envelope.payload.title ?? "Untitled article",
            author: envelope.payload.byline,
            siteName: envelope.payload.siteName,
            language: envelope.payload.language,
            publishedAt: envelope.payload.publishedTime,
            capturedAt: timestamp,
            captureMethod: envelope.method,
            packagePath: imported.snapshotURL.deletingLastPathComponent().path,
            contentSHA256: imported.sha256,
            extractorVersion: "schema-\(envelope.schemaVersion)",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
    }
}
