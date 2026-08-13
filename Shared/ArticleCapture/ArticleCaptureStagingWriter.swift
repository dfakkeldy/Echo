// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

nonisolated struct ArticleCaptureStagingWriter {
    enum FailurePoint: Sendable {
        case beforeFinalPublication
        case beforeCompletionMarker
    }

    enum Error: Swift.Error, LocalizedError {
        case envelopeTooLarge(Int)
        case packageAlreadyExists(UUID)
        case unsafeExistingPackage(URL)

        var errorDescription: String? {
            switch self {
            case .envelopeTooLarge(let bytes):
                return "Article capture envelope is \(bytes) bytes, exceeding the supported limit."
            case .packageAlreadyExists(let id):
                return "An article capture staging package already exists for \(id.uuidString)."
            case .unsafeExistingPackage(let url):
                return "The existing article capture staging package is unsafe to reconcile: \(url.path)"
            }
        }
    }

    let root: URL
    private let failurePoint: (@Sendable (FailurePoint) throws -> Void)?

    init(
        root: URL,
        failurePoint: (@Sendable (FailurePoint) throws -> Void)? = nil
    ) {
        self.root = root
        self.failurePoint = failurePoint
    }

    func stage(_ envelope: ArticleCaptureEnvelope) throws -> URL {
        try stagePackage(envelope, imageLocalization: nil, localizationRoot: nil)
    }

    func stage(
        _ envelope: ArticleCaptureEnvelope,
        imageLocalization: ArticleImageLocalization,
        localizationRoot: URL
    ) throws -> URL {
        try stagePackage(
            envelope,
            imageLocalization: imageLocalization,
            localizationRoot: localizationRoot)
    }

    private func stagePackage(
        _ envelope: ArticleCaptureEnvelope,
        imageLocalization: ArticleImageLocalization?,
        localizationRoot: URL?
    ) throws -> URL {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= ArticleWorkshopLimits.maxEnvelopeBytes else {
            throw Error.envelopeTooLarge(data.count)
        }

        let fileManager = FileManager.default
        let normalizedRoot = root.standardizedFileURL
        let package = normalizedRoot.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        let partial = normalizedRoot.appending(
            path: ".\(envelope.captureID.uuidString).partial", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: normalizedRoot, withIntermediateDirectories: true)
        try reconcileStaleAttempt(package: package, partial: partial, captureID: envelope.captureID)

        var ownsPartial = false
        do {
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
            ownsPartial = true
#if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: partial.path
            )
#endif
            try data.write(to: partial.appending(path: "envelope.json"), options: .atomic)
            if let imageLocalization, let localizationRoot {
                try stageImageAssets(
                    imageLocalization,
                    captureID: envelope.captureID,
                    sourceRoot: localizationRoot,
                    destination: partial)
            }
            try failurePoint?(.beforeFinalPublication)
            try fileManager.moveItem(at: partial, to: package)
            ownsPartial = false
            try failurePoint?(.beforeCompletionMarker)
            try Data().write(to: package.appending(path: "complete"), options: .atomic)
            return package
        } catch {
            if ownsPartial, fileManager.fileExists(atPath: partial.path) {
                try fileManager.removeItem(at: partial)
            }
            throw error
        }
    }

    private func stageImageAssets(
        _ localization: ArticleImageLocalization,
        captureID: UUID,
        sourceRoot: URL,
        destination: URL
    ) throws {
        let manifest = ArticleImageAssetManifest(
            schemaVersion: 1,
            captureID: captureID,
            assets: localization.assets,
            failures: localization.failures)
        let ownedIDs = manifest.assets.map(\.owningBlockID)
        let failedIDs = manifest.failures.map(\.owningBlockID)
        guard manifest.assets.count <= ArticleWorkshopLimits.maxImages,
            ownedIDs.count + failedIDs.count <= ArticleWorkshopLimits.maxBlocks,
            Set(ownedIDs).count == ownedIDs.count,
            Set(failedIDs).count == failedIDs.count,
            Set(ownedIDs).isDisjoint(with: failedIDs)
        else { throw Error.unsafeExistingPackage(destination) }
        let images = destination.appending(path: "images", directoryHint: .isDirectory)
        if manifest.assets.isEmpty == false {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        }
        var copiedPaths = Set<String>()
        var totalBytes = 0
        for descriptor in manifest.assets where copiedPaths.insert(descriptor.managedPath).inserted {
            let components = descriptor.managedPath.split(separator: "/")
            guard components.count == 2, components[0] == "images",
                descriptor.byteCount > 0,
                descriptor.byteCount <= ArticleWorkshopLimits.maxSingleImageBytes,
                totalBytes <= ArticleWorkshopLimits.maxTotalImageBytes - descriptor.byteCount
            else { throw Error.unsafeExistingPackage(destination) }
            let source = sourceRoot.appending(path: descriptor.managedPath)
            let values = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                values.fileSize == descriptor.byteCount
            else { throw Error.unsafeExistingPackage(source) }
            let imageData = try Data(contentsOf: source, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: imageData)
                .map { String(format: "%02x", $0) }.joined()
            guard digest == descriptor.sha256,
                ArticleImageValidator.isValid(
                    data: imageData,
                    mediaType: descriptor.mediaType)
            else { throw Error.unsafeExistingPackage(source) }
            try imageData.write(
                to: images.appending(path: components[1]),
                options: .withoutOverwriting)
            totalBytes += imageData.count
        }
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: destination.appending(path: "image-assets.json"),
            options: .atomic)
    }

    private func reconcileStaleAttempt(package: URL, partial: URL, captureID: UUID) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: partial.path) {
            guard try safeDirectory(partial) else { throw Error.unsafeExistingPackage(partial) }
            try fileManager.removeItem(at: partial)
        }
        guard fileManager.fileExists(atPath: package.path) else { return }
        guard try safeDirectory(package) else { throw Error.unsafeExistingPackage(package) }

        let marker = package.appending(path: "complete")
        if fileManager.fileExists(atPath: marker.path) {
            guard try regularEmptyFile(marker) else { throw Error.unsafeExistingPackage(package) }
            throw Error.packageAlreadyExists(captureID)
        }
        let children = try fileManager.contentsOfDirectory(
            at: package,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Error.unsafeExistingPackage(package) }
        }
        try fileManager.removeItem(at: package)
    }

    private func safeDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func regularEmptyFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        return values.isRegularFile == true && values.isSymbolicLink != true && values.fileSize == 0
    }
}
