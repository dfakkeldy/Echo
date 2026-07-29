// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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
