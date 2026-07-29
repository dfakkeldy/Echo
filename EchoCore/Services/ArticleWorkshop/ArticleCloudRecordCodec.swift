// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import CryptoKit
import Foundation
import ZIPFoundation

nonisolated struct ArticleCloudCapturePayload: Sendable {
    let capture: ArticleCaptureRecord
    let packageArchiveURL: URL
}

nonisolated struct ArticleCloudRevisionPayload: Sendable {
    let revision: ArticleRevisionRecord
}

nonisolated struct ArticleCloudAnthologyPayload: Sendable {
    let manifest: ArticleCloudAnthologyManifest
    let coverURL: URL?
}

nonisolated enum ArticleDecodedCloudRecord: Sendable {
    case capture(ArticleCloudCapturePayload)
    case revision(ArticleCloudRevisionPayload)
    case anthology(ArticleCloudAnthologyPayload)
}

/// Encodes private Article Workshop records and copies downloaded CloudKit assets
/// out of CloudKit-owned temporary storage before an event callback can return.
nonisolated struct ArticleCloudRecordCodec: Sendable {
    static let zoneName = "EchoArticleWorkshop.v1"

    struct Limits: Equatable, Sendable {
        let maxScalarBytes: Int
        let maxCanonicalJSONBytes: Int
        let maxPackageBytes: Int

        static let production = Limits(
            maxScalarBytes: 64 * 1_024,
            maxCanonicalJSONBytes: 1 * 1_024 * 1_024,
            maxPackageBytes: 64 * 1_024 * 1_024)
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case invalidEntityID(String)
        case invalidRecordName(String)
        case wrongZone
        case wrongRecordType(String)
        case missingField(String)
        case invalidField(String)
        case scalarTooLarge(String)
        case invalidJSON(String)
        case canonicalJSONTooLarge(String)
        case missingAsset(String)
        case unsafeFile
        case unsafeDirectory
        case packageTooLarge
        case invalidPackage
        case prohibitedField(String)
    }

    private enum Field {
        static let entityID = "entityID"
        static let sourceURL = "sourceURL"
        static let canonicalURL = "canonicalURL"
        static let title = "title"
        static let author = "author"
        static let siteName = "siteName"
        static let language = "language"
        static let publishedAt = "publishedAt"
        static let capturedAt = "capturedAt"
        static let captureMethod = "captureMethod"
        static let package = "package"
        static let contentSHA256 = "contentSHA256"
        static let extractorVersion = "extractorVersion"
        static let contentState = "contentState"
        static let warningsJSON = "warningsJSON"
        static let currentRevisionID = "currentRevisionID"
        static let createdAt = "createdAt"
        static let modifiedAt = "modifiedAt"

        static let captureID = "captureID"
        static let parentRevisionID = "parentRevisionID"
        static let metadataOverridesJSON = "metadataOverridesJSON"
        static let recipeJSON = "recipeJSON"
        static let readableContentSHA256 = "readableContentSHA256"
        static let deviceName = "deviceName"

        static let manifestJSON = "manifestJSON"
        static let cover = "cover"
    }

    private let temporaryDirectory: URL
    private let limits: Limits

    init(
        temporaryDirectory: URL = FileLocations.articleSyncTemporaryDirectory,
        limits: Limits = .production
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.limits = limits
    }

    func recordID(
        for type: ArticleCloudRecordType,
        entityID: UUID
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "\(type.recordNamePrefix).\(entityID.uuidString)",
            zoneID: zoneID)
    }

    func captureRecord(
        _ capture: ArticleCaptureRecord,
        packageDirectory: URL
    ) throws -> CKRecord {
        let id = try uuid(capture.id)
        try validateSHA256(capture.contentSHA256, field: Field.contentSHA256)
        let record = CKRecord(
            recordType: ArticleCloudRecordType.capture.rawValue,
            recordID: recordID(for: .capture, entityID: id))
        try set(capture.id, field: Field.entityID, on: record)
        try set(capture.sourceURL, field: Field.sourceURL, on: record)
        try setOptional(capture.canonicalURL, field: Field.canonicalURL, on: record)
        try set(capture.title, field: Field.title, on: record)
        try setOptional(capture.author, field: Field.author, on: record)
        try setOptional(capture.siteName, field: Field.siteName, on: record)
        try setOptional(capture.language, field: Field.language, on: record)
        try setOptional(capture.publishedAt, field: Field.publishedAt, on: record)
        try set(capture.capturedAt, field: Field.capturedAt, on: record)
        try set(capture.captureMethod.rawValue, field: Field.captureMethod, on: record)
        try set(capture.contentSHA256, field: Field.contentSHA256, on: record)
        try set(capture.extractorVersion, field: Field.extractorVersion, on: record)
        try set(capture.contentState, field: Field.contentState, on: record)
        try set(
            canonicalJSONString(capture.warningsJSON, field: Field.warningsJSON),
            field: Field.warningsJSON,
            on: record)
        try setOptional(
            capture.currentRevisionID,
            field: Field.currentRevisionID,
            on: record)
        if let currentRevisionID = capture.currentRevisionID {
            _ = try uuid(currentRevisionID)
        }
        try set(capture.createdAt, field: Field.createdAt, on: record)
        try set(capture.modifiedAt, field: Field.modifiedAt, on: record)

        try validateInstalledCapture(
            at: packageDirectory,
            expectedSHA256: capture.contentSHA256)
        let archiveURL = try makePackageArchive(
            packageDirectory: packageDirectory,
            recordName: record.recordID.recordName)
        record[Field.package] = CKAsset(fileURL: archiveURL)
        return record
    }

    func revisionRecord(_ revision: ArticleRevisionRecord) throws -> CKRecord {
        let id = try uuid(revision.id)
        _ = try uuid(revision.captureID)
        if let parentRevisionID = revision.parentRevisionID {
            _ = try uuid(parentRevisionID)
        }
        try validateSHA256(
            revision.readableContentSHA256,
            field: Field.readableContentSHA256)
        let record = CKRecord(
            recordType: ArticleCloudRecordType.revision.rawValue,
            recordID: recordID(for: .revision, entityID: id))
        try set(revision.id, field: Field.entityID, on: record)
        try set(revision.captureID, field: Field.captureID, on: record)
        try setOptional(
            revision.parentRevisionID,
            field: Field.parentRevisionID,
            on: record)
        try set(
            canonicalJSONString(
                revision.metadataOverridesJSON,
                field: Field.metadataOverridesJSON),
            field: Field.metadataOverridesJSON,
            on: record)
        try set(
            canonicalJSONString(revision.recipeJSON, field: Field.recipeJSON),
            field: Field.recipeJSON,
            on: record)
        try set(
            revision.readableContentSHA256,
            field: Field.readableContentSHA256,
            on: record)
        try set(revision.createdAt, field: Field.createdAt, on: record)
        try setOptional(revision.deviceName, field: Field.deviceName, on: record)
        return record
    }

    func anthologyRecord(
        _ manifest: ArticleCloudAnthologyManifest,
        coverURL: URL?
    ) throws -> CKRecord {
        let id = try uuid(manifest.anthology.id)
        var cloudManifest = manifest
        cloudManifest.anthology.coverPath = nil
        cloudManifest.anthology.latestBuildRevision = 0
        try validateManifest(cloudManifest)
        let record = CKRecord(
            recordType: ArticleCloudRecordType.anthology.rawValue,
            recordID: recordID(for: .anthology, entityID: id))
        try set(manifest.anthology.id, field: Field.entityID, on: record)
        try set(
            canonicalJSONString(cloudManifest, field: Field.manifestJSON),
            field: Field.manifestJSON,
            on: record)
        if let coverURL {
            try validateRegularFile(coverURL, maximumBytes: limits.maxPackageBytes)
            let staged = try copyAsset(
                from: coverURL,
                into: temporaryDirectory.appending(
                    path: "Outgoing",
                    directoryHint: .isDirectory),
                fileName: "\(record.recordID.recordName)-cover-\(UUID().uuidString)")
            record[Field.cover] = CKAsset(fileURL: staged)
        }
        return record
    }

    func decode(
        _ record: CKRecord,
        assetCopyDirectory: URL
    ) throws -> ArticleDecodedCloudRecord {
        let type = try validatedTypeAndIdentity(record)
        try rejectProhibitedFields(record)
        try rejectUnknownFields(record, type: type)
        switch type {
        case .capture:
            return .capture(
                try decodeCapture(
                    record,
                    assetCopyDirectory: assetCopyDirectory))
        case .revision:
            return .revision(try decodeRevision(record))
        case .anthology:
            return .anthology(
                try decodeAnthology(
                    record,
                    assetCopyDirectory: assetCopyDirectory))
        }
    }

    func deletedRecordIdentity(
        recordID: CKRecord.ID,
        recordType: String
    ) throws -> (type: ArticleCloudRecordType, entityID: String) {
        guard recordID.zoneID == zoneID else { throw Error.wrongZone }
        guard let type = ArticleCloudRecordType(rawValue: recordType) else {
            throw Error.wrongRecordType(recordType)
        }
        let entityID = try validatedEntityID(recordID: recordID, type: type)
        return (type, entityID)
    }

    /// Installs a validated downloaded capture archive into the managed
    /// Article Workshop tree and returns a database-safe record with no
    /// CloudKit temporary path.
    func installCapturePackage(
        _ payload: ArticleCloudCapturePayload,
        workshopRootDirectory: URL = FileLocations.articleWorkshopRootDirectory
    ) throws -> ArticleCaptureRecord {
        let captureID = try uuid(payload.capture.id)
        try validateSHA256(
            payload.capture.contentSHA256,
            field: Field.contentSHA256)
        try validatePackageArchive(payload.packageArchiveURL)

        let capturesRoot = workshopRootDirectory.appending(
            path: "Captures",
            directoryHint: .isDirectory)
        try createSafeDirectory(capturesRoot)
        let destination = capturesRoot.appending(
            path: captureID.uuidString,
            directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            try validateInstalledCapture(
                at: destination,
                expectedSHA256: payload.capture.contentSHA256)
            var installed = payload.capture
            installed.packagePath = destination.path
            return installed
        }

        let partial = capturesRoot.appending(
            path: ".\(captureID.uuidString)-sync-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: partial,
                withIntermediateDirectories: false)
            try extractPackageArchive(payload.packageArchiveURL, to: partial)
            try validateInstalledCapture(
                at: partial,
                expectedSHA256: payload.capture.contentSHA256)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: partial.path) {
                try? FileManager.default.removeItem(at: partial)
            }
            throw error
        }

        var installed = payload.capture
        installed.packagePath = destination.path
        return installed
    }

    private func decodeCapture(
        _ record: CKRecord,
        assetCopyDirectory: URL
    ) throws -> ArticleCloudCapturePayload {
        let entityID = try requiredString(Field.entityID, from: record)
        try validateEntityID(entityID, for: .capture, record: record)
        let methodRaw = try requiredString(Field.captureMethod, from: record)
        guard let method = ArticleCaptureMethod(rawValue: methodRaw) else {
            throw Error.invalidField(Field.captureMethod)
        }
        let warnings = try canonicalJSONString(
            requiredString(Field.warningsJSON, from: record),
            field: Field.warningsJSON)
        let sourceURL = try requiredString(Field.sourceURL, from: record)
        let canonicalURL = try optionalString(Field.canonicalURL, from: record)
        let title = try requiredString(Field.title, from: record)
        let author = try optionalString(Field.author, from: record)
        let siteName = try optionalString(Field.siteName, from: record)
        let language = try optionalString(Field.language, from: record)
        let publishedAt = try optionalString(Field.publishedAt, from: record)
        let capturedAt = try requiredString(Field.capturedAt, from: record)
        let contentSHA256 = try requiredString(Field.contentSHA256, from: record)
        try validateSHA256(contentSHA256, field: Field.contentSHA256)
        let extractorVersion = try requiredString(Field.extractorVersion, from: record)
        let contentState = try requiredString(Field.contentState, from: record)
        let currentRevisionID = try optionalString(Field.currentRevisionID, from: record)
        if let currentRevisionID {
            _ = try uuid(currentRevisionID)
        }
        let createdAt = try requiredString(Field.createdAt, from: record)
        let modifiedAt = try requiredString(Field.modifiedAt, from: record)
        guard let asset = record[Field.package] as? CKAsset, let source = asset.fileURL else {
            throw Error.missingAsset(Field.package)
        }
        try validatePackageArchive(source)
        let copied = try copyAsset(
            from: source,
            into: assetCopyDirectory,
            fileName: "\(record.recordID.recordName)-\(UUID().uuidString).zip")
        let capture = ArticleCaptureRecord(
            id: entityID,
            sourceURL: sourceURL,
            canonicalURL: canonicalURL,
            title: title,
            author: author,
            siteName: siteName,
            language: language,
            publishedAt: publishedAt,
            capturedAt: capturedAt,
            captureMethod: method,
            packagePath: copied.path,
            contentSHA256: contentSHA256,
            extractorVersion: extractorVersion,
            contentState: contentState,
            warningsJSON: warnings,
            currentRevisionID: currentRevisionID,
            createdAt: createdAt,
            modifiedAt: modifiedAt)
        return ArticleCloudCapturePayload(
            capture: capture,
            packageArchiveURL: copied)
    }

    private func decodeRevision(_ record: CKRecord) throws -> ArticleCloudRevisionPayload {
        let entityID = try requiredString(Field.entityID, from: record)
        try validateEntityID(entityID, for: .revision, record: record)
        let captureID = try requiredString(Field.captureID, from: record)
        _ = try uuid(entityID)
        _ = try uuid(captureID)
        let parentRevisionID = try optionalString(Field.parentRevisionID, from: record)
        if let parentRevisionID {
            _ = try uuid(parentRevisionID)
        }
        let revision = ArticleRevisionRecord(
            id: entityID,
            captureID: captureID,
            parentRevisionID: parentRevisionID,
            metadataOverridesJSON: try canonicalJSONString(
                requiredString(Field.metadataOverridesJSON, from: record),
                field: Field.metadataOverridesJSON),
            recipeJSON: try canonicalJSONString(
                requiredString(Field.recipeJSON, from: record),
                field: Field.recipeJSON),
            readableContentSHA256: try requiredString(
                Field.readableContentSHA256,
                from: record),
            createdAt: try requiredString(Field.createdAt, from: record),
            deviceName: try optionalString(Field.deviceName, from: record))
        try validateSHA256(
            revision.readableContentSHA256,
            field: Field.readableContentSHA256)
        return ArticleCloudRevisionPayload(revision: revision)
    }

    private func decodeAnthology(
        _ record: CKRecord,
        assetCopyDirectory: URL
    ) throws -> ArticleCloudAnthologyPayload {
        let json = try canonicalJSONString(
            requiredString(Field.manifestJSON, from: record),
            field: Field.manifestJSON)
        let manifest: ArticleCloudAnthologyManifest
        do {
            manifest = try JSONDecoder().decode(
                ArticleCloudAnthologyManifest.self,
                from: Data(json.utf8))
        } catch {
            throw Error.invalidJSON(Field.manifestJSON)
        }
        guard manifest.anthology.id == (try requiredString(Field.entityID, from: record))
        else {
            throw Error.invalidField(Field.manifestJSON)
        }
        try validateEntityID(manifest.anthology.id, for: .anthology, record: record)
        try validateManifest(manifest)
        guard try canonicalJSONString(manifest, field: Field.manifestJSON) == json else {
            throw Error.invalidJSON(Field.manifestJSON)
        }
        let coverURL: URL?
        if let asset = record[Field.cover] as? CKAsset {
            guard let source = asset.fileURL else {
                throw Error.missingAsset(Field.cover)
            }
            try validateRegularFile(source, maximumBytes: limits.maxPackageBytes)
            coverURL = try copyAsset(
                from: source,
                into: assetCopyDirectory,
                fileName: "\(record.recordID.recordName)-cover-\(UUID().uuidString)")
        } else if record[Field.cover] != nil {
            throw Error.invalidField(Field.cover)
        } else {
            coverURL = nil
        }
        return ArticleCloudAnthologyPayload(
            manifest: manifest,
            coverURL: coverURL)
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: Self.zoneName,
            ownerName: CKCurrentUserDefaultName)
    }

    private func validatedTypeAndIdentity(
        _ record: CKRecord
    ) throws -> ArticleCloudRecordType {
        guard record.recordID.zoneID == zoneID else { throw Error.wrongZone }
        guard let type = ArticleCloudRecordType(rawValue: record.recordType) else {
            throw Error.wrongRecordType(record.recordType)
        }
        _ = try validatedEntityID(recordID: record.recordID, type: type)
        return type
    }

    private func validatedEntityID(
        recordID: CKRecord.ID,
        type: ArticleCloudRecordType
    ) throws -> String {
        let prefix = "\(type.recordNamePrefix)."
        guard recordID.recordName.hasPrefix(prefix) else {
            throw Error.invalidRecordName(recordID.recordName)
        }
        let suffix = String(recordID.recordName.dropFirst(prefix.count))
        let id = try uuid(suffix)
        guard recordID.recordName == "\(type.recordNamePrefix).\(id.uuidString)" else {
            throw Error.invalidRecordName(recordID.recordName)
        }
        return id.uuidString
    }

    private func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), id.uuidString == value else {
            throw Error.invalidEntityID(value)
        }
        return id
    }

    private func set(
        _ value: String,
        field: String,
        on record: CKRecord
    ) throws {
        try validateScalar(value, field: field)
        record[field] = value as CKRecordValue
    }

    private func setOptional(
        _ value: String?,
        field: String,
        on record: CKRecord
    ) throws {
        guard let value else { return }
        try set(value, field: field, on: record)
    }

    private func requiredString(_ field: String, from record: CKRecord) throws -> String {
        guard let value = record[field] as? String else {
            throw Error.missingField(field)
        }
        try validateScalar(value, field: field)
        return value
    }

    private func optionalString(_ field: String, from record: CKRecord) throws -> String? {
        guard let raw = record[field] else { return nil }
        guard let value = raw as? String else { throw Error.invalidField(field) }
        try validateScalar(value, field: field)
        return value
    }

    private func validateScalar(_ value: String, field: String) throws {
        guard value.utf8.count <= limits.maxScalarBytes else {
            throw Error.scalarTooLarge(field)
        }
    }

    private func validateSHA256(_ value: String, field: String) throws {
        guard value.count == 64,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw Error.invalidField(field)
        }
    }

    private func validateEntityID(
        _ entityID: String,
        for type: ArticleCloudRecordType,
        record: CKRecord
    ) throws {
        let id = try uuid(entityID)
        guard record.recordID.recordName == "\(type.recordNamePrefix).\(id.uuidString)" else {
            throw Error.invalidRecordName(record.recordID.recordName)
        }
    }

    private func validateManifest(_ manifest: ArticleCloudAnthologyManifest) throws {
        guard manifest.schemaVersion == 1,
            manifest.anthology.coverPath == nil,
            manifest.anthology.latestBuildRevision == 0,
            manifest.anthology.nextStableSlot >= 0
        else {
            throw Error.invalidField(Field.manifestJSON)
        }
        _ = try uuid(manifest.anthology.id)
        try validateScalar(manifest.anthology.title, field: Field.title)
        for optional in [manifest.anthology.subtitle, manifest.anthology.creator] {
            if let optional {
                try validateScalar(optional, field: Field.manifestJSON)
            }
        }

        guard manifest.entries.map(\.sortOrder) == Array(0..<manifest.entries.count),
            Set(manifest.entries.map(\.id)).count == manifest.entries.count,
            Set(manifest.entries.map(\.captureID)).count == manifest.entries.count,
            Set(manifest.entries.map(\.stableSlot)).count == manifest.entries.count
        else {
            throw Error.invalidField(Field.manifestJSON)
        }
        for entry in manifest.entries {
            _ = try uuid(entry.id)
            _ = try uuid(entry.captureID)
            guard entry.anthologyID == manifest.anthology.id,
                entry.stableSlot >= 0,
                entry.stableSlot < manifest.anthology.nextStableSlot
            else {
                throw Error.invalidField(Field.manifestJSON)
            }
            for optional in [entry.chapterTitleOverride, entry.narrationVoiceID] {
                if let optional {
                    try validateScalar(optional, field: Field.manifestJSON)
                }
            }
        }
    }

    private func canonicalJSONString(_ value: String, field: String) throws -> String {
        let data = Data(value.utf8)
        guard data.count <= limits.maxCanonicalJSONBytes else {
            throw Error.canonicalJSONTooLarge(field)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw Error.invalidJSON(field)
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw Error.invalidJSON(field)
        }
        let canonical: Data
        do {
            canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw Error.invalidJSON(field)
        }
        guard canonical.count <= limits.maxCanonicalJSONBytes,
            let result = String(data: canonical, encoding: .utf8)
        else {
            throw Error.canonicalJSONTooLarge(field)
        }
        return result
    }

    private func canonicalJSONString<T: Encodable>(_ value: T, field: String) throws
        -> String
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= limits.maxCanonicalJSONBytes,
            let result = String(data: data, encoding: .utf8)
        else {
            throw Error.canonicalJSONTooLarge(field)
        }
        return result
    }

    private func makePackageArchive(
        packageDirectory: URL,
        recordName: String
    ) throws -> URL {
        try validatePackageDirectory(packageDirectory)
        let outgoing = temporaryDirectory.appending(
            path: "Outgoing",
            directoryHint: .isDirectory)
        try createSafeDirectory(outgoing)
        let destination = outgoing.appending(
            path: "\(recordName)-\(UUID().uuidString).zip")
        try FileManager.default.zipItem(
            at: packageDirectory,
            to: destination,
            shouldKeepParent: false,
            compressionMethod: .deflate)
        do {
            try validatePackageArchive(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func validatePackageDirectory(_ directory: URL) throws {
        let normalized = directory.standardizedFileURL
        guard normalized == directory,
            try isDirectoryWithoutSymlink(directory)
        else {
            throw Error.unsafeDirectory
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: [])
        else {
            throw Error.unsafeDirectory
        }
        var total = 0
        var count = 0
        var sawSnapshot = false
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            guard values.isSymbolicLink != true else { throw Error.unsafeFile }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw Error.unsafeFile
            }
            count += 1
            guard count <= ArticleWorkshopLimits.maxImages + 2,
                total <= limits.maxPackageBytes - size
            else {
                throw Error.packageTooLarge
            }
            total += size
            if url.lastPathComponent == "snapshot.json" {
                sawSnapshot = true
            }
        }
        guard sawSnapshot else { throw Error.invalidPackage }
    }

    private func validatePackageArchive(_ url: URL) throws {
        try validateRegularFile(url, maximumBytes: limits.maxPackageBytes)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw Error.invalidPackage
        }
        var total: UInt64 = 0
        var count = 0
        var sawSnapshot = false
        var paths: Set<String> = []
        for entry in archive {
            if entry.type == .directory { continue }
            guard isSafeArchivePath(entry.path) else {
                throw Error.invalidPackage
            }
            guard entry.type == .file else { throw Error.invalidPackage }
            guard paths.insert(entry.path).inserted else { throw Error.invalidPackage }
            count += 1
            guard count <= ArticleWorkshopLimits.maxImages + 2,
                entry.uncompressedSize <= UInt64(limits.maxPackageBytes),
                total <= UInt64(limits.maxPackageBytes) - entry.uncompressedSize
            else {
                throw Error.packageTooLarge
            }
            total += entry.uncompressedSize
            if entry.path == "snapshot.json" {
                sawSnapshot = true
            }
        }
        guard sawSnapshot else { throw Error.invalidPackage }
    }

    private func extractPackageArchive(_ url: URL, to directory: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw Error.invalidPackage
        }
        for entry in archive {
            if entry.type == .directory { continue }
            guard isSafeArchivePath(entry.path) else { throw Error.invalidPackage }
            guard entry.type == .file else { throw Error.invalidPackage }
            let destination = directory.appending(path: entry.path).standardizedFileURL
            let root = directory.standardizedFileURL
            guard destination.path.hasPrefix(root.path + "/") else {
                throw Error.invalidPackage
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination)
        }
    }

    private func validateInstalledCapture(
        at directory: URL,
        expectedSHA256: String
    ) throws {
        try validatePackageDirectory(directory)
        let snapshot = directory.appending(path: "snapshot.json")
        try validateRegularFile(snapshot, maximumBytes: limits.maxPackageBytes)
        let data = try Data(
            contentsOf: snapshot,
            options: [.mappedIfSafe])
        guard data.count <= limits.maxPackageBytes,
            SHA256.hash(data: data)
                .map({ String(format: "%02x", $0) })
                .joined() == expectedSHA256
        else {
            throw Error.invalidPackage
        }
    }

    private func isSafeArchivePath(_ path: String) -> Bool {
        guard path.isEmpty == false, path.hasPrefix("/") == false else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { $0.isEmpty == false && $0 != "." && $0 != ".." }
    }

    private func validateRegularFile(_ url: URL, maximumBytes: Int) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size >= 0,
            size <= maximumBytes
        else {
            throw Error.unsafeFile
        }
    }

    private func copyAsset(from source: URL, into directory: URL, fileName: String) throws -> URL {
        try validateRegularFile(source, maximumBytes: limits.maxPackageBytes)
        try createSafeDirectory(directory)
        let destination = directory.appending(path: fileName)
        guard
            destination.standardizedFileURL.deletingLastPathComponent()
                == directory.standardizedFileURL,
            FileManager.default.fileExists(atPath: destination.path) == false
        else {
            throw Error.unsafeFile
        }
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try validateRegularFile(destination, maximumBytes: limits.maxPackageBytes)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func createSafeDirectory(_ directory: URL) throws {
        let normalized = directory.standardizedFileURL
        guard normalized == directory else { throw Error.unsafeDirectory }
        if FileManager.default.fileExists(atPath: directory.path) {
            guard try isDirectoryWithoutSymlink(directory) else {
                throw Error.unsafeDirectory
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            guard try isDirectoryWithoutSymlink(directory) else {
                throw Error.unsafeDirectory
            }
        }
    }

    private func isDirectoryWithoutSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func rejectProhibitedFields(_ record: CKRecord) throws {
        let prohibited = [
            "contentXHTML",
            "textContent",
            "packagePath",
            "coverPath",
            "generatedEPUB",
            "narration",
            "m4b",
            "credentials",
            "cookies",
            "error",
            "rawError",
        ]
        if let field = prohibited.first(where: { record[$0] != nil }) {
            throw Error.prohibitedField(field)
        }
    }

    private func rejectUnknownFields(
        _ record: CKRecord,
        type: ArticleCloudRecordType
    ) throws {
        let allowed: Set<String>
        switch type {
        case .capture:
            allowed = [
                Field.entityID,
                Field.sourceURL,
                Field.canonicalURL,
                Field.title,
                Field.author,
                Field.siteName,
                Field.language,
                Field.publishedAt,
                Field.capturedAt,
                Field.captureMethod,
                Field.package,
                Field.contentSHA256,
                Field.extractorVersion,
                Field.contentState,
                Field.warningsJSON,
                Field.currentRevisionID,
                Field.createdAt,
                Field.modifiedAt,
            ]
        case .revision:
            allowed = [
                Field.entityID,
                Field.captureID,
                Field.parentRevisionID,
                Field.metadataOverridesJSON,
                Field.recipeJSON,
                Field.readableContentSHA256,
                Field.createdAt,
                Field.deviceName,
            ]
        case .anthology:
            allowed = [
                Field.entityID,
                Field.manifestJSON,
                Field.cover,
            ]
        }
        if let unknown = record.allKeys().first(where: { allowed.contains($0) == false }) {
            throw Error.prohibitedField(unknown)
        }
    }
}
