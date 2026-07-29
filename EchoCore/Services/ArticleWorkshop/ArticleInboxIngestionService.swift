// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@MainActor
struct ArticleInboxIngestionService {
    enum CleanupPoint {
        case beforeQuarantine
        case afterQuarantine
    }

    enum Error: Swift.Error, LocalizedError {
        case conflictingExistingCapture(UUID)
        case unsafeStagingRoot(URL)
        case unsafeStagingPackage(URL)
        case unreconciledCleanupPackage(URL)

        var errorDescription: String? {
            switch self {
            case .conflictingExistingCapture(let id):
                return "The existing article capture record for \(id.uuidString) does not match the staged package."
            case .unsafeStagingRoot(let url):
                return "Article capture staging root is unsafe: \(url.path)"
            case .unsafeStagingPackage(let url):
                return "Article capture staging package is unsafe: \(url.path)"
            case .unreconciledCleanupPackage(let url):
                return "Article capture cleanup package cannot be safely reconciled: \(url.path)"
            }
        }
    }

    let captureDAO: ArticleCaptureDAO
    let fileStore: ArticleWorkshopFileStore
    let stagingRoot: URL
    private let cleanupHook: ((CleanupPoint, URL) throws -> Void)?

    init(
        captureDAO: ArticleCaptureDAO,
        fileStore: ArticleWorkshopFileStore = ArticleWorkshopFileStore(),
        stagingRoot: URL,
        cleanupHook: ((CleanupPoint, URL) throws -> Void)? = nil
    ) {
        self.captureDAO = captureDAO
        self.fileStore = fileStore
        self.stagingRoot = stagingRoot
        self.cleanupHook = cleanupHook
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
        let reconciledCaptureIDs = try reconcileQuarantinedPackages(
            in: packages,
            stagingRoot: normalizedRoot
        )
        for package in packages {
            guard let captureID = UUID(uuidString: package.lastPathComponent) else { continue }
            guard reconciledCaptureIDs.contains(captureID) == false else { continue }
            guard package.standardizedFileURL.deletingLastPathComponent() == normalizedRoot else { continue }
            guard try safeDirectory(package) else { throw Error.unsafeStagingPackage(package) }
            guard fileManager.fileExists(atPath: package.appending(path: "complete").path) else { continue }

            let imported = try fileStore.importEnvelope(at: package)
            let expected = record(for: imported)
            if let existing = try captureDAO.capture(id: imported.envelope.captureID.uuidString) {
                guard existing == expected else {
                    throw Error.conflictingExistingCapture(imported.envelope.captureID)
                }
                try cleanup(package: package, imported: imported, stagingRoot: normalizedRoot)
                continue
            }

            try captureDAO.saveCapture(expected)
            try cleanup(package: package, imported: imported, stagingRoot: normalizedRoot)
        }
    }

    private func reconcileQuarantinedPackages(
        in entries: [URL],
        stagingRoot: URL
    ) throws -> Set<UUID> {
        let fileManager = FileManager.default
        var reconciledCaptureIDs = Set<UUID>()

        for cleanupRoot in entries where cleanupRoot.lastPathComponent.hasPrefix(".cleanup-") {
            guard cleanupRoot.standardizedFileURL.deletingLastPathComponent() == stagingRoot,
                  try safeDirectory(cleanupRoot),
                  let captureID = captureID(inCleanupRoot: cleanupRoot)
            else {
                throw Error.unreconciledCleanupPackage(cleanupRoot)
            }

            let children = try fileManager.contentsOfDirectory(
                at: cleanupRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            if children.isEmpty {
                try fileManager.removeItem(at: cleanupRoot)
                continue
            }

            guard children.count == 1 else {
                throw Error.unreconciledCleanupPackage(cleanupRoot)
            }
            let quarantined = children[0]
            guard quarantined.lastPathComponent == captureID.uuidString,
                  quarantined.standardizedFileURL.deletingLastPathComponent() == cleanupRoot,
                  try safeDirectory(quarantined)
            else {
                throw Error.unreconciledCleanupPackage(cleanupRoot)
            }

            let validated = try fileStore.validateEnvelope(at: quarantined)
            guard validated.envelope.captureID == captureID else {
                throw Error.unreconciledCleanupPackage(quarantined)
            }
            let durablePackage = fileStore.root
                .appending(path: "Captures", directoryHint: .isDirectory)
                .appending(path: captureID.uuidString, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: durablePackage.path),
                  try safeDirectory(durablePackage)
            else {
                throw Error.unreconciledCleanupPackage(quarantined)
            }

            let imported = try fileStore.importEnvelope(at: quarantined)
            guard imported.sha256 == validated.sha256 else {
                throw Error.unreconciledCleanupPackage(quarantined)
            }
            let expected = record(for: imported)
            guard let existing = try captureDAO.capture(id: captureID.uuidString), existing == expected else {
                throw Error.conflictingExistingCapture(captureID)
            }

            try fileManager.removeItem(at: quarantined)
            try fileManager.removeItem(at: cleanupRoot)
            reconciledCaptureIDs.insert(captureID)
        }

        return reconciledCaptureIDs
    }

    private func cleanup(
        package: URL,
        imported: ArticleWorkshopFileStore.ImportedEnvelope,
        stagingRoot: URL
    ) throws {
        let fileManager = FileManager.default
        try cleanupHook?(.beforeQuarantine, package)
        guard package.standardizedFileURL.deletingLastPathComponent() == stagingRoot,
              try safeDirectory(package)
        else {
            throw Error.unsafeStagingPackage(package)
        }

        let cleanupRoot = stagingRoot.appending(
            path: ".cleanup-\(imported.envelope.captureID.uuidString)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let quarantined = cleanupRoot.appending(
            path: imported.envelope.captureID.uuidString,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: cleanupRoot, withIntermediateDirectories: false)
        do {
            try fileManager.moveItem(at: package, to: quarantined)
        } catch {
            try fileManager.removeItem(at: cleanupRoot)
            throw error
        }

        do {
            try cleanupHook?(.afterQuarantine, package)
            guard cleanupRoot.standardizedFileURL.deletingLastPathComponent() == stagingRoot,
                  quarantined.standardizedFileURL.deletingLastPathComponent() == cleanupRoot,
                  try safeDirectory(cleanupRoot),
                  try safeDirectory(quarantined)
            else {
                throw Error.unsafeStagingPackage(quarantined)
            }
            let validated = try fileStore.validateEnvelope(at: quarantined)
            guard validated.sha256 == imported.sha256 else {
                throw Error.conflictingExistingCapture(imported.envelope.captureID)
            }
            try fileManager.removeItem(at: quarantined)
            try fileManager.removeItem(at: cleanupRoot)
        } catch {
            throw error
        }
    }

    private func safeDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func captureID(inCleanupRoot cleanupRoot: URL) -> UUID? {
        let name = cleanupRoot.lastPathComponent
        let prefix = ".cleanup-"
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
        guard suffix.count == 73 else { return nil }
        let captureEnd = suffix.index(suffix.startIndex, offsetBy: 36)
        guard suffix[captureEnd] == "-" else { return nil }
        let captureIDString = String(suffix[..<captureEnd])
        let nonceString = String(suffix[suffix.index(after: captureEnd)...])
        guard let captureID = UUID(uuidString: captureIDString),
              let nonce = UUID(uuidString: nonceString),
              name == ".cleanup-\(captureID.uuidString)-\(nonce.uuidString)"
        else {
            return nil
        }
        return captureID
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
