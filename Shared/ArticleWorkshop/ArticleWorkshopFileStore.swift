// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated struct ArticleWorkshopFileStore {
    enum Error: Swift.Error, LocalizedError {
        case incompletePackage(URL)
        case invalidCaptureDirectory(URL)
        case envelopeTooLarge(Int)
        case unsupportedSchemaVersion(Int)
        case captureIDMismatch(expected: UUID, actual: UUID)
        case destinationDigestMismatch(UUID)

        var errorDescription: String? {
            switch self {
            case .incompletePackage(let url):
                return "Article capture package is incomplete: \(url.path)"
            case .invalidCaptureDirectory(let url):
                return "Article capture package has an invalid directory name: \(url.path)"
            case .envelopeTooLarge(let bytes):
                return "Article capture envelope is \(bytes) bytes, exceeding the supported limit."
            case .unsupportedSchemaVersion(let version):
                return "Article capture schema version \(version) is not supported."
            case .captureIDMismatch(let expected, let actual):
                return "Article capture package ID \(expected.uuidString) does not match envelope ID \(actual.uuidString)."
            case .destinationDigestMismatch(let id):
                return "The durable article capture for \(id.uuidString) has a different digest."
            }
        }
    }

    struct ImportedEnvelope: Sendable {
        let envelope: ArticleCaptureEnvelope
        let snapshotURL: URL
        let sha256: String
    }

    let root: URL

    init(root: URL = FileLocations.articleWorkshopRootDirectory) {
        self.root = root
    }

    func importEnvelope(at package: URL) throws -> ImportedEnvelope {
        let fileManager = FileManager.default
        let marker = package.appending(path: "complete")
        guard fileManager.fileExists(atPath: marker.path) else {
            throw Error.incompletePackage(package)
        }
        guard let directoryID = UUID(uuidString: package.lastPathComponent) else {
            throw Error.invalidCaptureDirectory(package)
        }

        let source = package.appending(path: "envelope.json")
        let data = try Data(contentsOf: source)
        guard data.count <= ArticleWorkshopLimits.maxEnvelopeBytes else {
            throw Error.envelopeTooLarge(data.count)
        }
        let envelope = try JSONDecoder.articleWorkshop.decode(ArticleCaptureEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else {
            throw Error.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard directoryID == envelope.captureID else {
            throw Error.captureIDMismatch(expected: directoryID, actual: envelope.captureID)
        }
        let digest = Self.sha256(data)
        let destination = root
            .appending(path: "Captures", directoryHint: .isDirectory)
            .appending(path: directoryID.uuidString, directoryHint: .isDirectory)
        let snapshot = destination.appending(path: "snapshot.json")

        if fileManager.fileExists(atPath: destination.path) {
            let durableData = try Data(contentsOf: snapshot)
            guard Self.sha256(durableData) == digest else {
                throw Error.destinationDigestMismatch(directoryID)
            }
            return ImportedEnvelope(envelope: envelope, snapshotURL: snapshot, sha256: digest)
        }

        let capturesRoot = root.appending(path: "Captures", directoryHint: .isDirectory)
        let partial = capturesRoot.appending(
            path: ".\(directoryID.uuidString).partial", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
        try data.write(to: partial.appending(path: "snapshot.json"), options: .atomic)
        try fileManager.moveItem(at: partial, to: destination)

        let durableData = try Data(contentsOf: snapshot)
        guard Self.sha256(durableData) == digest else {
            throw Error.destinationDigestMismatch(directoryID)
        }
        return ImportedEnvelope(envelope: envelope, snapshotURL: snapshot, sha256: digest)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
