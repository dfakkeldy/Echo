// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@MainActor
struct ArticleInboxIngestionService {
    enum Error: Swift.Error, LocalizedError {
        case conflictingExistingCapture(UUID)
        case unsafeStagingRoot(URL)
        case unsafeStagingPackage(URL)

        var errorDescription: String? {
            switch self {
            case .conflictingExistingCapture(let id):
                return "The existing article capture record for \(id.uuidString) does not match the staged package."
            case .unsafeStagingRoot(let url):
                return "Article capture staging root is unsafe: \(url.path)"
            case .unsafeStagingPackage(let url):
                return "Article capture staging package is unsafe: \(url.path)"
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
        let normalizedRoot = stagingRoot.standardizedFileURL
        guard fileManager.fileExists(atPath: normalizedRoot.path) else { return }
        guard try safeDirectory(normalizedRoot) else { throw Error.unsafeStagingRoot(normalizedRoot) }
        let packages = try fileManager.contentsOfDirectory(
            at: normalizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for package in packages {
            guard UUID(uuidString: package.lastPathComponent) != nil else { continue }
            guard package.standardizedFileURL.deletingLastPathComponent() == normalizedRoot else { continue }
            guard try safeDirectory(package) else { throw Error.unsafeStagingPackage(package) }
            guard fileManager.fileExists(atPath: package.appending(path: "complete").path) else { continue }

            let imported = try fileStore.importEnvelope(at: package)
            let expected = record(for: imported)
            if let existing = try captureDAO.capture(id: imported.envelope.captureID.uuidString) {
                guard existing == expected else {
                    throw Error.conflictingExistingCapture(imported.envelope.captureID)
                }
                _ = try fileStore.validateEnvelope(at: package)
                try fileManager.removeItem(at: package)
                continue
            }

            try captureDAO.saveCapture(expected)
            _ = try fileStore.validateEnvelope(at: package)
            try fileManager.removeItem(at: package)
        }
    }

    private func safeDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
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
