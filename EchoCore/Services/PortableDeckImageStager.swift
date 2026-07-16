// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Stages, publishes, commits, or rolls back the bundled images
/// (`imageFile`) of a portable study deck into per-deck storage under
/// `Application Support/DeckMediaV2/<safeDeckID>`, using a
/// stage-then-publish-then-commit-or-rollback protocol so a failure at any
/// point never leaves a deck's images half-copied or a prior successful
/// import's images clobbered:
///
/// 1. `stage(relativePaths:beside:deckID:)` resolves every source symlink,
///    verifies containment under the deck bundle's directory, verifies each
///    source is a nonempty regular file of a supported image type, and
///    copies each into a fresh transaction-scoped staging directory under a
///    collision-safe (content-hashed) filename. Any failure removes the
///    staging directory and rethrows.
/// 2. `publish(_:)` atomically swaps the staged directory into place as the
///    deck's final image directory, moving any pre-existing directory aside
///    to a transaction-scoped backup first. Any failure restores that
///    backup and rethrows.
/// 3. After the caller's database write succeeds, `commit(_:)` removes the
///    now-superseded backup (if any); after it fails, `rollback(_:)`
///    removes the newly published directory and restores the backup.
///
/// `nonisolated`: pure, synchronous `FileManager` work with no actor
/// affinity, callable from the (MainActor-isolated) `DeckImportService`
/// without hopping actors.
nonisolated struct PortableDeckImageStager {
    struct StagedSet: Sendable {
        let stagingRoot: URL
        let finalRoot: URL
        let backupRoot: URL
        let mediaPathByRelativePath: [String: String]
    }

    struct PublishedSet: Sendable {
        let staged: StagedSet
        let hadPreviousDirectory: Bool
    }

    func stage(
        relativePaths: [String],
        beside deckURL: URL,
        deckID: String
    ) throws -> StagedSet {
        let manager = FileManager.default
        let bundleRoot = deckURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let mediaRoot = URL.applicationSupportDirectory
            .appending(path: "DeckMediaV2", directoryHint: .isDirectory)
        let safeDeckID = SHA256.hash(data: Data(deckID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let finalRoot = mediaRoot.appending(path: safeDeckID, directoryHint: .isDirectory)
        let transactionID = UUID().uuidString
        let stagingRoot = mediaRoot.appending(
            path: ".staging-\(safeDeckID)-\(transactionID)",
            directoryHint: .isDirectory
        )
        let backupRoot = mediaRoot.appending(
            path: ".backup-\(safeDeckID)-\(transactionID)",
            directoryHint: .isDirectory
        )
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        do {
            var paths: [String: String] = [:]
            for relativePath in relativePaths.sorted() {
                let source = bundleRoot.appending(path: relativePath)
                    .resolvingSymlinksInPath().standardizedFileURL
                guard source.path.hasPrefix(bundleRoot.path + "/") else {
                    throw DeckImportError.unsafeImagePath(relativePath)
                }
                let values = try source.resourceValues(forKeys: [
                    .isRegularFileKey, .fileSizeKey,
                ])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw DeckImportError.invalidImageFile(relativePath)
                }
                let fileExtension = source.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "webp", "heic"].contains(fileExtension) else {
                    throw DeckImportError.unsupportedImageType(relativePath)
                }
                let filename = SHA256.hash(data: Data(relativePath.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                    + "." + fileExtension
                let stagedURL = stagingRoot.appending(path: filename)
                try manager.copyItem(at: source, to: stagedURL)
                paths[relativePath] = finalRoot.appending(path: filename).path
            }
            return StagedSet(
                stagingRoot: stagingRoot,
                finalRoot: finalRoot,
                backupRoot: backupRoot,
                mediaPathByRelativePath: paths
            )
        } catch let stagingError {
            do {
                try removeIfPresent(stagingRoot, using: manager)
            } catch let cleanupError {
                throw DeckImportError.imageStagingCleanupFailed(
                    primary: stagingError,
                    cleanup: cleanupError
                )
            }
            throw stagingError
        }
    }

    func publish(_ staged: StagedSet) throws -> PublishedSet {
        let manager = FileManager.default
        try manager.createDirectory(
            at: staged.finalRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let hadPrevious = manager.fileExists(atPath: staged.finalRoot.path)
        if hadPrevious {
            try manager.moveItem(at: staged.finalRoot, to: staged.backupRoot)
        }
        do {
            try manager.moveItem(at: staged.stagingRoot, to: staged.finalRoot)
            return PublishedSet(staged: staged, hadPreviousDirectory: hadPrevious)
        } catch let publicationError {
            do {
                if hadPrevious {
                    try manager.moveItem(at: staged.backupRoot, to: staged.finalRoot)
                }
            } catch let recoveryError {
                throw DeckImportError.imagePublicationRecoveryFailed(
                    primary: publicationError,
                    recovery: recoveryError
                )
            }
            throw publicationError
        }
    }

    func commit(_ published: PublishedSet) throws {
        if published.hadPreviousDirectory {
            try removeIfPresent(
                published.staged.backupRoot,
                using: FileManager.default
            )
        }
    }

    func rollback(_ published: PublishedSet) throws {
        let manager = FileManager.default
        try removeIfPresent(published.staged.finalRoot, using: manager)
        if published.hadPreviousDirectory {
            try manager.moveItem(
                at: published.staged.backupRoot,
                to: published.staged.finalRoot
            )
        }
    }

    func discard(_ staged: StagedSet) throws {
        let manager = FileManager.default
        try removeIfPresent(staged.stagingRoot, using: manager)
        try removeIfPresent(staged.backupRoot, using: manager)
    }

    private func removeIfPresent(_ url: URL, using manager: FileManager) throws {
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }
}
