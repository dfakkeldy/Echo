// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ArticleCaptureStagingWriter {
    enum Error: Swift.Error, LocalizedError {
        case envelopeTooLarge(Int)
        case packageAlreadyExists(UUID)

        var errorDescription: String? {
            switch self {
            case .envelopeTooLarge(let bytes):
                return "Article capture envelope is \(bytes) bytes, exceeding the supported limit."
            case .packageAlreadyExists(let id):
                return "An article capture staging package already exists for \(id.uuidString)."
            }
        }
    }

    let root: URL

    init(root: URL) {
        self.root = root
    }

    func stage(_ envelope: ArticleCaptureEnvelope) throws -> URL {
        let data = try JSONEncoder.articleWorkshop.encode(envelope)
        guard data.count <= ArticleWorkshopLimits.maxEnvelopeBytes else {
            throw Error.envelopeTooLarge(data.count)
        }

        let fileManager = FileManager.default
        let package = root.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        let partial = root.appending(
            path: ".\(envelope.captureID.uuidString).partial", directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: package.path) else {
            throw Error.packageAlreadyExists(envelope.captureID)
        }
        guard !fileManager.fileExists(atPath: partial.path) else {
            throw Error.packageAlreadyExists(envelope.captureID)
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: partial.path
        )
#endif
        try data.write(to: partial.appending(path: "envelope.json"), options: .atomic)
        try fileManager.moveItem(at: partial, to: package)
        try Data().write(to: package.appending(path: "complete"), options: .atomic)
        return package
    }
}
