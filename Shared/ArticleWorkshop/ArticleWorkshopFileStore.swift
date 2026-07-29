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
        case unsafePackage(URL)
        case unsafeFile(URL)
        case fileChangedDuringValidation(URL)

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
            case .unsafePackage(let url):
                return "Article capture package is not a regular directory: \(url.path)"
            case .unsafeFile(let url):
                return "Article capture package contains an unsafe file: \(url.path)"
            case .fileChangedDuringValidation(let url):
                return "Article capture package changed during validation: \(url.path)"
            }
        }
    }

    struct ImportedEnvelope: Sendable {
        let envelope: ArticleCaptureEnvelope
        let snapshotURL: URL
        let sha256: String
    }

    struct ValidatedEnvelope: Sendable {
        let envelope: ArticleCaptureEnvelope
        let sha256: String
    }

    let root: URL

    init(root: URL = FileLocations.articleWorkshopRootDirectory) {
        self.root = root
    }

    func importEnvelope(at package: URL) throws -> ImportedEnvelope {
        let validated = try validateEnvelope(at: package)
        let fileManager = FileManager.default
        let directoryID = validated.envelope.captureID
        let destination = root
            .appending(path: "Captures", directoryHint: .isDirectory)
            .appending(path: directoryID.uuidString, directoryHint: .isDirectory)
        let snapshot = destination.appending(path: "snapshot.json")

        if fileManager.fileExists(atPath: destination.path) {
            guard try safeDirectory(destination) else { throw Error.unsafePackage(destination) }
            let durableData = try boundedRegularFileData(at: snapshot)
            guard Self.sha256(durableData) == validated.sha256 else {
                throw Error.destinationDigestMismatch(directoryID)
            }
            return ImportedEnvelope(envelope: validated.envelope, snapshotURL: snapshot, sha256: validated.sha256)
        }

        let capturesRoot = root.appending(path: "Captures", directoryHint: .isDirectory)
        let partial = capturesRoot.appending(
            path: ".\(directoryID.uuidString).partial", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
        let sourceData = try boundedRegularFileData(at: package.appending(path: "envelope.json"))
        guard Self.sha256(sourceData) == validated.sha256 else {
            throw Error.fileChangedDuringValidation(package.appending(path: "envelope.json"))
        }
        try sourceData.write(to: partial.appending(path: "snapshot.json"), options: .atomic)
        try fileManager.moveItem(at: partial, to: destination)

        let durableData = try boundedRegularFileData(at: snapshot)
        guard Self.sha256(durableData) == validated.sha256 else {
            throw Error.destinationDigestMismatch(directoryID)
        }
        return ImportedEnvelope(envelope: validated.envelope, snapshotURL: snapshot, sha256: validated.sha256)
    }

    func validateEnvelope(at package: URL) throws -> ValidatedEnvelope {
        let normalized = package.standardizedFileURL
        guard normalized == package, try safeDirectory(normalized) else {
            throw Error.unsafePackage(package)
        }
        guard let directoryID = UUID(uuidString: normalized.lastPathComponent) else {
            throw Error.invalidCaptureDirectory(normalized)
        }
        let marker = normalized.appending(path: "complete")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw Error.incompletePackage(normalized)
        }
        guard try regularFileSize(marker) == 0 else { throw Error.unsafeFile(marker) }

        let source = normalized.appending(path: "envelope.json")
        let data = try boundedRegularFileData(at: source)
        let envelope = try JSONDecoder.articleWorkshop.decode(ArticleCaptureEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else {
            throw Error.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard directoryID == envelope.captureID else {
            throw Error.captureIDMismatch(expected: directoryID, actual: envelope.captureID)
        }
        return ValidatedEnvelope(envelope: envelope, sha256: Self.sha256(data))
    }

    private func boundedRegularFileData(at url: URL) throws -> Data {
        let sizeBefore = try regularFileSize(url)
        guard sizeBefore <= ArticleWorkshopLimits.maxEnvelopeBytes else {
            throw Error.envelopeTooLarge(sizeBefore)
        }
        let handle = try FileHandle(forReadingFrom: url)
        let data = try handle.read(upToCount: ArticleWorkshopLimits.maxEnvelopeBytes + 1) ?? Data()
        try handle.close()
        guard data.count <= ArticleWorkshopLimits.maxEnvelopeBytes else {
            throw Error.envelopeTooLarge(data.count)
        }
        let sizeAfter = try regularFileSize(url)
        guard sizeBefore == sizeAfter, sizeAfter == data.count else {
            throw Error.fileChangedDuringValidation(url)
        }
        return data
    }

    private func regularFileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw Error.unsafeFile(url)
        }
        return size
    }

    private func safeDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
