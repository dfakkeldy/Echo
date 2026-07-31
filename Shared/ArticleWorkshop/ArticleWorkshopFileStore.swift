// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation

nonisolated struct ArticleWorkshopFileStore {
    enum ValidationPoint: Equatable, Sendable {
        case afterRead
    }

    enum Error: Swift.Error, LocalizedError {
        case incompletePackage(URL)
        case invalidCaptureDirectory(URL)
        case envelopeTooLarge(Int)
        case unsupportedSchemaVersion(Int)
        case captureIDMismatch(expected: UUID, actual: UUID)
        case destinationDigestMismatch(UUID)
        case captureRecordIDInvalid(String)
        case contentDigestMismatch(UUID)
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
            case .captureRecordIDInvalid(let id):
                return "The article capture record has an invalid identifier: \(id)."
            case .contentDigestMismatch(let id):
                return "The durable article capture for \(id.uuidString) no longer matches its stored digest."
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
    private let validationHook: @Sendable (ValidationPoint, URL) throws -> Void

    init(
        root: URL = FileLocations.articleWorkshopRootDirectory,
        validationHook: @escaping @Sendable (ValidationPoint, URL) throws -> Void = { _, _ in }
    ) {
        self.root = root
        self.validationHook = validationHook
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

    func loadSnapshot(for record: ArticleCaptureRecord) throws -> ArticleSnapshot {
        guard let captureID = UUID(uuidString: record.id) else {
            throw Error.captureRecordIDInvalid(record.id)
        }
        let capturesRoot = root.appending(path: "Captures", directoryHint: .isDirectory)
        let package = capturesRoot.appending(
            path: captureID.uuidString,
            directoryHint: .isDirectory)
        let snapshotURL = package.appending(path: "snapshot.json")

        guard try exactDirectory(root) else { throw Error.unsafePackage(root) }
        guard try exactDirectory(capturesRoot) else {
            throw Error.unsafePackage(capturesRoot)
        }
        guard try exactDirectory(package) else { throw Error.unsafePackage(package) }
        let data = try boundedRegularFileData(at: snapshotURL)
        guard Self.sha256(data) == record.contentSHA256 else {
            throw Error.contentDigestMismatch(captureID)
        }
        let envelope = try JSONDecoder.articleWorkshop.decode(
            ArticleCaptureEnvelope.self,
            from: data)
        guard envelope.schemaVersion == 1 else {
            throw Error.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.captureID == captureID else {
            throw Error.captureIDMismatch(
                expected: captureID,
                actual: envelope.captureID)
        }
        return try ArticleBlockSanitizer().sanitize(envelope: envelope)
    }

    private func boundedRegularFileData(at url: URL) throws -> Data {
        let pathBefore = try pathMetadataWithoutFollowingLeaf(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let metadataBefore = try descriptorMetadata(
            handle.fileDescriptor,
            url: url)
        guard pathBefore.hasSameIdentity(as: metadataBefore) else {
            throw Error.fileChangedDuringValidation(url)
        }
        guard
            metadataBefore.size
                <= Int64(ArticleWorkshopLimits.maxEnvelopeBytes)
        else {
            throw Error.envelopeTooLarge(Int(metadataBefore.size))
        }
        let data =
            try handle.read(
                upToCount: ArticleWorkshopLimits.maxEnvelopeBytes + 1)
            ?? Data()
        try validationHook(.afterRead, url)
        let metadataAfter = try descriptorMetadata(
            handle.fileDescriptor,
            url: url)
        guard metadataBefore == metadataAfter else {
            throw Error.fileChangedDuringValidation(url)
        }
        let livePath = try pathMetadataWithoutFollowingLeaf(at: url)
        guard metadataAfter.hasSameIdentity(as: livePath) else {
            throw Error.fileChangedDuringValidation(url)
        }
        guard data.count <= ArticleWorkshopLimits.maxEnvelopeBytes else {
            throw Error.envelopeTooLarge(data.count)
        }
        guard metadataAfter.size == Int64(data.count) else {
            throw Error.fileChangedDuringValidation(url)
        }
        return data
    }

    private func descriptorMetadata(
        _ descriptor: Int32,
        url: URL
    ) throws -> FileMetadata {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw Error.unsafeFile(url)
        }
        return try fileMetadata(information, url: url)
    }

    private func pathMetadataWithoutFollowingLeaf(at url: URL) throws -> FileMetadata {
        var information = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &information)
        }
        guard result == 0 else {
            throw Error.unsafeFile(url)
        }
        return try fileMetadata(information, url: url)
    }

    private func fileMetadata(
        _ information: stat,
        url: URL
    ) throws -> FileMetadata {
        guard
            (information.st_mode & S_IFMT) == S_IFREG,
            information.st_size >= 0
        else {
            throw Error.unsafeFile(url)
        }
        return FileMetadata(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: Int64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            changeSeconds: Int64(information.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(information.st_ctimespec.tv_nsec),
        )
    }

    private func regularFileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw Error.unsafeFile(url)
        }
        return size
    }

    private func safeDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func exactDirectory(_ url: URL) throws -> Bool {
        guard url.standardizedFileURL == url else { return false }
        guard try safeDirectory(url) else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated struct FileMetadata: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    func hasSameIdentity(as other: FileMetadata) -> Bool {
        device == other.device && inode == other.inode
    }
}
