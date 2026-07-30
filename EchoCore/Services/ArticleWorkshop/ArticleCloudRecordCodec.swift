// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import CryptoKit
import Foundation
import ZIPFoundation

nonisolated struct ArticleCloudCaptureAssetDescriptor:
    Codable, Equatable, Sendable
{
    let path: String
    let sha256: String
    let mediaType: String
}

nonisolated struct ArticleCloudCapturePayload: Sendable {
    let capture: ArticleCaptureRecord
    let packageArchiveURL: URL
    let packageAssets: [ArticleCloudCaptureAssetDescriptor]
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
        case invalidSystemFields
        case invalidProvenance(String)
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
        static let packageAssetsJSON = "packageAssetsJSON"
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
        static let coverContentVersion = "coverContentVersion"
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
        packageDirectory: URL,
        baseSystemFields: Data? = nil
    ) throws -> CKRecord {
        let id = try uuid(capture.id)
        try validateSHA256(capture.contentSHA256, field: Field.contentSHA256)
        try validateProvenanceURL(capture.sourceURL, field: Field.sourceURL)
        if let canonicalURL = capture.canonicalURL {
            try validateProvenanceURL(canonicalURL, field: Field.canonicalURL)
        }
        let record = try record(
            type: .capture,
            entityID: id,
            baseSystemFields: baseSystemFields)
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

        let packageAssets = try validatePackageDirectory(packageDirectory)
        try validateInstalledCapture(
            at: packageDirectory,
            expected: capture)
        try set(
            canonicalJSONString(packageAssets, field: Field.packageAssetsJSON),
            field: Field.packageAssetsJSON,
            on: record)
        let archiveURL = try makePackageArchive(
            packageDirectory: packageDirectory,
            recordName: record.recordID.recordName)
        record[Field.package] = CKAsset(fileURL: archiveURL)
        return record
    }

    func revisionRecord(
        _ revision: ArticleRevisionRecord,
        baseSystemFields: Data? = nil
    ) throws -> CKRecord {
        var canonicalRevision = revision
        canonicalRevision.metadataOverridesJSON = try canonicalJSONString(
            revision.metadataOverridesJSON,
            field: Field.metadataOverridesJSON)
        canonicalRevision.recipeJSON = try canonicalJSONString(
            revision.recipeJSON,
            field: Field.recipeJSON)
        let id = try uuid(revision.id)
        _ = try uuid(revision.captureID)
        if let parentRevisionID = revision.parentRevisionID {
            _ = try uuid(parentRevisionID)
        }
        try validateSHA256(
            revision.readableContentSHA256,
            field: Field.readableContentSHA256)
        try validateRevisionJSON(canonicalRevision)
        let record = try record(
            type: .revision,
            entityID: id,
            baseSystemFields: baseSystemFields)
        try set(revision.id, field: Field.entityID, on: record)
        try set(revision.captureID, field: Field.captureID, on: record)
        try setOptional(
            revision.parentRevisionID,
            field: Field.parentRevisionID,
            on: record)
        try set(
            canonicalRevision.metadataOverridesJSON,
            field: Field.metadataOverridesJSON,
            on: record)
        try set(
            canonicalRevision.recipeJSON,
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
        coverURL: URL?,
        baseSystemFields: Data? = nil
    ) throws -> CKRecord {
        let id = try uuid(manifest.anthology.id)
        var cloudManifest = manifest
        cloudManifest.anthology.coverPath = nil
        cloudManifest.anthology.latestBuildRevision = 0
        try validateManifest(cloudManifest)
        let record = try record(
            type: .anthology,
            entityID: id,
            baseSystemFields: baseSystemFields)
        try set(manifest.anthology.id, field: Field.entityID, on: record)
        try set(
            canonicalJSONString(cloudManifest, field: Field.manifestJSON),
            field: Field.manifestJSON,
            on: record)
        if let coverURL {
            try validateRegularFile(coverURL, maximumBytes: limits.maxPackageBytes)
            let coverContentVersion = try AnthologyCoverStore()
                .contentVersion(for: coverURL)
            if let expected = manifest.coverContentVersion,
                expected != coverContentVersion
            {
                throw Error.invalidField(Field.coverContentVersion)
            }
            try set(
                coverContentVersion,
                field: Field.coverContentVersion,
                on: record)
            let staged = try copyAsset(
                from: coverURL,
                into: temporaryDirectory.appending(
                    path: "Outgoing",
                    directoryHint: .isDirectory),
                fileName: "\(record.recordID.recordName)-cover-\(UUID().uuidString)")
            record[Field.cover] = CKAsset(fileURL: staged)
        } else if manifest.coverContentVersion != nil {
            throw Error.missingAsset(Field.cover)
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

    func systemFields(for record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    func contentFingerprint(for record: CKRecord) throws -> String {
        let fields = try record.allKeys().sorted().compactMap { key -> String? in
            if record[key] is CKAsset { return nil }
            guard let value = record[key] else { return nil }
            if let string = value as? String {
                return "\(key)\u{0}\(string)"
            }
            if let number = value as? NSNumber {
                return "\(key)\u{0}\(number.stringValue)"
            }
            throw Error.invalidField(key)
        }
        let data = Data(fields.joined(separator: "\u{1}").utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func validateCaptureArchive(at url: URL) throws {
        _ = try validatePackageArchive(url)
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
        let packageAssets = try validatePackageArchive(payload.packageArchiveURL)
        guard packageAssets == payload.packageAssets else {
            throw Error.invalidPackage
        }

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
                expected: payload.capture)
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
            guard try validatePackageDirectory(partial) == payload.packageAssets else {
                throw Error.invalidPackage
            }
            try validateInstalledCapture(
                at: partial,
                expected: payload.capture)
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
        let warnings = try requireCanonicalJSONString(
            requiredString(Field.warningsJSON, from: record),
            field: Field.warningsJSON)
        let sourceURL = try requiredString(Field.sourceURL, from: record)
        let canonicalURL = try optionalString(Field.canonicalURL, from: record)
        try validateProvenanceURL(sourceURL, field: Field.sourceURL)
        if let canonicalURL {
            try validateProvenanceURL(canonicalURL, field: Field.canonicalURL)
        }
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
        let packageAssetsJSON = try requireCanonicalJSONString(
            requiredString(Field.packageAssetsJSON, from: record),
            field: Field.packageAssetsJSON)
        let packageAssets: [ArticleCloudCaptureAssetDescriptor]
        do {
            packageAssets = try JSONDecoder().decode(
                [ArticleCloudCaptureAssetDescriptor].self,
                from: Data(packageAssetsJSON.utf8))
        } catch {
            throw Error.invalidJSON(Field.packageAssetsJSON)
        }
        guard
            try canonicalJSONString(
                packageAssets,
                field: Field.packageAssetsJSON) == packageAssetsJSON
        else {
            throw Error.invalidJSON(Field.packageAssetsJSON)
        }
        guard let asset = record[Field.package] as? CKAsset, let source = asset.fileURL else {
            throw Error.missingAsset(Field.package)
        }
        guard try validatePackageArchive(source) == packageAssets else {
            throw Error.invalidPackage
        }
        let copied = try copyAsset(
            from: source,
            into: assetCopyDirectory,
            fileName: "\(record.recordID.recordName)-\(UUID().uuidString).zip")
        guard try validatePackageArchive(copied) == packageAssets else {
            try? FileManager.default.removeItem(at: copied)
            throw Error.invalidPackage
        }
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
            packageArchiveURL: copied,
            packageAssets: packageAssets)
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
            metadataOverridesJSON: try requireCanonicalJSONString(
                requiredString(Field.metadataOverridesJSON, from: record),
                field: Field.metadataOverridesJSON),
            recipeJSON: try requireCanonicalJSONString(
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
        try validateRevisionJSON(revision)
        return ArticleCloudRevisionPayload(revision: revision)
    }

    private func decodeAnthology(
        _ record: CKRecord,
        assetCopyDirectory: URL
    ) throws -> ArticleCloudAnthologyPayload {
        let json = try requireCanonicalJSONString(
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
        let coverContentVersion = try optionalString(
            Field.coverContentVersion,
            from: record)
        if let asset = record[Field.cover] as? CKAsset {
            guard let coverContentVersion else {
                throw Error.missingField(Field.coverContentVersion)
            }
            try validateCoverContentVersion(coverContentVersion)
            guard let source = asset.fileURL else {
                throw Error.missingAsset(Field.cover)
            }
            try validateRegularFile(source, maximumBytes: limits.maxPackageBytes)
            guard
                try AnthologyCoverStore().contentVersion(for: source)
                    == coverContentVersion
            else {
                throw Error.invalidField(Field.coverContentVersion)
            }
            coverURL = try copyAsset(
                from: source,
                into: assetCopyDirectory,
                fileName: "\(record.recordID.recordName)-cover-\(UUID().uuidString)")
        } else if record[Field.cover] != nil {
            throw Error.invalidField(Field.cover)
        } else if coverContentVersion != nil {
            throw Error.missingAsset(Field.cover)
        } else {
            coverURL = nil
        }
        var syncedManifest = manifest
        syncedManifest.coverContentVersion = coverContentVersion
        return ArticleCloudAnthologyPayload(
            manifest: syncedManifest,
            coverURL: coverURL)
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: Self.zoneName,
            ownerName: CKCurrentUserDefaultName)
    }

    private func record(
        type: ArticleCloudRecordType,
        entityID: UUID,
        baseSystemFields: Data?
    ) throws -> CKRecord {
        let expectedID = recordID(for: type, entityID: entityID)
        guard let baseSystemFields else {
            return CKRecord(recordType: type.rawValue, recordID: expectedID)
        }
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: baseSystemFields)
        } catch {
            throw Error.invalidSystemFields
        }
        defer { unarchiver.finishDecoding() }
        unarchiver.requiresSecureCoding = true
        guard let restored = CKRecord(coder: unarchiver),
            restored.recordID == expectedID,
            restored.recordType == type.rawValue
        else {
            throw Error.invalidSystemFields
        }
        // System fields are the server concurrency base. Every application
        // field is rewritten from a currently validated local model.
        for key in restored.allKeys() {
            restored[key] = nil
        }
        return restored
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

    private func validateProvenanceURL(_ value: String, field: String) throws {
        try validateScalar(value, field: field)
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            throw Error.invalidProvenance(field)
        }
        let sensitiveNames: Set<String> = [
            "access_key", "access_token", "accesskey", "accesstoken", "api_key",
            "apikey", "authorization", "auth", "bearer", "client_secret", "code",
            "credential", "credentials", "cookie", "jwt", "key", "password",
            "passwd", "secret", "session", "sessionid", "sig", "signature", "token",
        ]
        let sensitiveTokens: Set<String> = [
            "auth", "authorization", "bearer", "code", "credential", "credentials",
            "cookie", "jwt", "key", "password", "passwd", "secret", "session",
            "sessionid", "sig", "signature", "token",
        ]
        let sensitiveValueMarkers: [String] = [
            "access_token", "api_key", "apikey", "authorization", "bearer ",
            "credential", "jwt", "password", "secret", "session=", "token=",
        ]
        guard
            queryContainsCredentials(
                components,
                depth: 0,
                sensitiveNames: sensitiveNames,
                sensitiveTokens: sensitiveTokens,
                sensitiveValueMarkers: sensitiveValueMarkers) == false
        else {
            throw Error.invalidProvenance(field)
        }
    }

    private func queryContainsCredentials(
        _ components: URLComponents,
        depth: Int,
        sensitiveNames: Set<String>,
        sensitiveTokens: Set<String>,
        sensitiveValueMarkers: [String]
    ) -> Bool {
        for item in components.queryItems ?? [] {
            guard let decodedName = repeatedlyPercentDecoded(item.name) else {
                return true
            }
            let name = normalizedQueryName(decodedName)
            let tokens = name.split(separator: "_").map(String.init)
            if sensitiveNames.contains(name)
                || tokens.contains(where: sensitiveTokens.contains)
            {
                return true
            }
            guard let itemValue = item.value else { continue }
            guard let decodedValue = repeatedlyPercentDecoded(itemValue) else {
                return true
            }
            let lowercasedValue = decodedValue.lowercased()
            if sensitiveValueMarkers.contains(where: lowercasedValue.contains) {
                return true
            }
            guard let nested = URLComponents(string: decodedValue),
                let scheme = nested.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                nested.host?.isEmpty == false
            else {
                continue
            }
            guard depth < 3 else { return true }
            if nested.user != nil || nested.password != nil || nested.fragment != nil {
                return true
            }
            if queryContainsCredentials(
                nested,
                depth: depth + 1,
                sensitiveNames: sensitiveNames,
                sensitiveTokens: sensitiveTokens,
                sensitiveValueMarkers: sensitiveValueMarkers)
            {
                return true
            }
        }
        return false
    }

    /// URLComponents decodes query components once. Repeat a small, bounded
    /// number of passes so credentials cannot be hidden behind nested escapes;
    /// values requiring more passes fail closed.
    private func repeatedlyPercentDecoded(
        _ value: String,
        maximumPasses: Int = 4
    ) -> String? {
        var current = value
        for _ in 0..<maximumPasses {
            guard let decoded = current.removingPercentEncoding else {
                return nil
            }
            if decoded == current {
                return current
            }
            current = decoded
        }
        guard let next = current.removingPercentEncoding,
            next == current
        else {
            return nil
        }
        return current
    }

    private func validateSnapshotURLAttributes(
        _ contentXHTML: String,
        sourceURL: String
    ) throws {
        guard let baseURL = URL(string: sourceURL) else {
            throw Error.invalidPackage
        }
        let collector = SnapshotURLAttributeCollector()
        let parser = XMLParser(data: Data(contentXHTML.utf8))
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), collector.containsRejectedSyntax == false else {
            throw Error.invalidPackage
        }

        for attribute in collector.attributes {
            let candidates: [String]
            guard
                let semantics =
                    SnapshotURLAttributeCollector.semantics[attribute.name]
            else {
                throw Error.invalidPackage
            }
            switch semantics {
            case .single:
                candidates = [attribute.value]
            case .whitespaceList:
                candidates = attribute.value.split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                guard candidates.isEmpty == false else {
                    throw Error.invalidPackage
                }
            case .srcset:
                candidates = try srcsetURLCandidates(attribute.value)
            case .css:
                candidates = try cssURLCandidates(attribute.value)
            }
            for candidate in candidates {
                try validateSnapshotURLCandidate(candidate, relativeTo: baseURL)
            }
        }
    }

    private func srcsetURLCandidates(_ value: String) throws -> [String] {
        var candidates: [String] = []
        var remainder = value[...]
        while true {
            while let first = remainder.first,
                first.isWhitespace || first == ","
            {
                remainder.removeFirst()
            }
            guard remainder.isEmpty == false else { break }

            let urlEnd =
                remainder.firstIndex(where: \.isWhitespace)
                ?? remainder.endIndex
            var rawURL = String(remainder[..<urlEnd])
            remainder = remainder[urlEnd...]
            var endedAtComma = false
            while rawURL.last == "," {
                rawURL.removeLast()
                endedAtComma = true
            }
            guard rawURL.isEmpty == false else {
                throw Error.invalidPackage
            }
            candidates.append(rawURL)
            var commaSearch = rawURL.startIndex
            while let comma = rawURL[commaSearch...].firstIndex(of: ",") {
                let suffixStart = rawURL.index(after: comma)
                if suffixStart < rawURL.endIndex {
                    candidates.append(String(rawURL[suffixStart...]))
                }
                commaSearch = suffixStart
            }

            if endedAtComma == false {
                while remainder.first?.isWhitespace == true {
                    remainder.removeFirst()
                }
                let descriptorEnd =
                    remainder.firstIndex(of: ",")
                    ?? remainder.endIndex
                let descriptor = remainder[..<descriptorEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if descriptor.isEmpty == false,
                    validImageCandidateDescriptor(descriptor) == false
                {
                    throw Error.invalidPackage
                }
                remainder = remainder[descriptorEnd...]
            }
            if remainder.first == "," {
                remainder.removeFirst()
            }
        }
        guard candidates.isEmpty == false else { throw Error.invalidPackage }
        return candidates
    }

    private func validImageCandidateDescriptor(_ descriptor: String) -> Bool {
        let pieces = descriptor.split(whereSeparator: \.isWhitespace)
        guard pieces.count == 1, let piece = pieces.first else { return false }
        if piece.hasSuffix("x") || piece.hasSuffix("dppx") {
            let suffix = piece.hasSuffix("dppx") ? "dppx" : "x"
            return Double(piece.dropLast(suffix.count)).map { $0 > 0 } ?? false
        }
        if piece.hasSuffix("dpi") {
            return Double(piece.dropLast(3)).map { $0 > 0 } ?? false
        }
        if piece.hasSuffix("w") || piece.hasSuffix("h") {
            return Int(piece.dropLast()).map { $0 > 0 } ?? false
        }
        return false
    }

    private func cssURLCandidates(_ css: String) throws -> [String] {
        guard css.contains("\\") == false,
            css.contains("/*") == false,
            css.contains("*/") == false
        else {
            throw Error.invalidPackage
        }
        let functionNames = ["url(", "image-set(", "-webkit-image-set("]
        var candidates: [String] = []
        var unchecked = ""
        var cursor = css.startIndex
        while cursor < css.endIndex {
            let matches = functionNames.compactMap { name -> (String, Range<String.Index>)? in
                guard
                    let range = css.range(
                        of: name,
                        options: [.caseInsensitive],
                        range: cursor..<css.endIndex)
                else {
                    return nil
                }
                return (name, range)
            }
            guard
                let match = matches.min(by: {
                    $0.1.lowerBound < $1.1.lowerBound
                })
            else {
                unchecked += css[cursor...]
                break
            }
            unchecked += css[cursor..<match.1.lowerBound]
            let parsed = try cssFunctionContent(
                in: css,
                openParenthesis: css.index(before: match.1.upperBound))
            if match.0 == "url(" {
                candidates.append(try cssURLArgument(parsed.content))
            } else {
                candidates.append(
                    contentsOf: try cssImageSetCandidates(parsed.content))
            }
            cursor = parsed.endIndex
        }
        let uncheckedLower = unchecked.lowercased()
        guard uncheckedLower.contains("url") == false,
            uncheckedLower.contains("image-set") == false,
            uncheckedLower.contains("@import") == false
        else {
            throw Error.invalidPackage
        }
        return candidates
    }

    private func cssFunctionContent(
        in value: String,
        openParenthesis: String.Index
    ) throws -> (content: String, endIndex: String.Index) {
        guard value[openParenthesis] == "(" else {
            throw Error.invalidPackage
        }
        var depth = 1
        var quote: Character?
        var index = value.index(after: openParenthesis)
        let contentStart = index
        while index < value.endIndex {
            let character = value[index]
            if character == "\\" {
                throw Error.invalidPackage
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return (
                        String(value[contentStart..<index]),
                        value.index(after: index)
                    )
                }
            }
            index = value.index(after: index)
        }
        throw Error.invalidPackage
    }

    private func cssURLArgument(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { throw Error.invalidPackage }
        if let quote = value.first, quote == "\"" || quote == "'" {
            guard value.last == quote, value.count >= 2 else {
                throw Error.invalidPackage
            }
            return String(value.dropFirst().dropLast())
        }
        guard value.contains(where: \.isWhitespace) == false,
            value.contains("\"") == false,
            value.contains("'") == false,
            value.contains("(") == false,
            value.contains(")") == false
        else {
            throw Error.invalidPackage
        }
        return value
    }

    private func cssImageSetCandidates(_ content: String) throws -> [String] {
        let options = try splitCSSImageSetOptions(content)
        guard options.isEmpty == false else { throw Error.invalidPackage }
        return try options.map { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("url(") {
                guard let open = trimmed.firstIndex(of: "(") else {
                    throw Error.invalidPackage
                }
                let parsed = try cssFunctionContent(
                    in: trimmed,
                    openParenthesis: open)
                let remainder = trimmed[parsed.endIndex...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    remainder.isEmpty
                        || validImageCandidateDescriptor(remainder)
                else {
                    throw Error.invalidPackage
                }
                return try cssURLArgument(parsed.content)
            }
            guard let quote = trimmed.first,
                quote == "\"" || quote == "'",
                let endQuote = trimmed.dropFirst().firstIndex(of: quote)
            else {
                throw Error.invalidPackage
            }
            let candidate = String(
                trimmed[trimmed.index(after: trimmed.startIndex)..<endQuote])
            let remainder = trimmed[trimmed.index(after: endQuote)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard remainder.isEmpty || validImageCandidateDescriptor(remainder)
            else {
                throw Error.invalidPackage
            }
            return candidate
        }
    }

    private func splitCSSImageSetOptions(_ content: String) throws -> [String] {
        var options: [String] = []
        var depth = 0
        var quote: Character?
        var start = content.startIndex
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            if character == "\\" {
                throw Error.invalidPackage
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                guard depth > 0 else { throw Error.invalidPackage }
                depth -= 1
            } else if character == ",", depth == 0 {
                options.append(String(content[start..<index]))
                start = content.index(after: index)
            }
            index = content.index(after: index)
        }
        guard quote == nil, depth == 0 else { throw Error.invalidPackage }
        options.append(String(content[start...]))
        return options
    }

    private func validateSnapshotURLCandidate(
        _ rawValue: String,
        relativeTo baseURL: URL,
        depth: Int = 0
    ) throws {
        guard depth <= 3 else { throw Error.invalidPackage }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false,
            value.unicodeScalars.allSatisfy({
                CharacterSet.controlCharacters.contains($0) == false
            }),
            let decoded = repeatedlyPercentDecoded(value),
            let resolved = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
            let components = URLComponents(
                url: resolved,
                resolvingAgainstBaseURL: true),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil
        else {
            throw Error.invalidPackage
        }
        let sensitiveNames: Set<String> = [
            "access_key", "access_token", "accesskey", "accesstoken", "api_key",
            "apikey", "authorization", "auth", "bearer", "client_secret", "code",
            "credential", "credentials", "cookie", "jwt", "key", "password",
            "passwd", "secret", "session", "sessionid", "sig", "signature", "token",
        ]
        let sensitiveTokens: Set<String> = [
            "auth", "authorization", "bearer", "code", "credential", "credentials",
            "cookie", "jwt", "key", "password", "passwd", "secret", "session",
            "sessionid", "sig", "signature", "token",
        ]
        let sensitiveValueMarkers: [String] = [
            "access_token", "api_key", "apikey", "authorization", "bearer ",
            "credential", "jwt", "password", "secret", "session=", "token=",
        ]
        guard
            queryContainsCredentials(
                components,
                depth: 0,
                sensitiveNames: sensitiveNames,
                sensitiveTokens: sensitiveTokens,
                sensitiveValueMarkers: sensitiveValueMarkers) == false
        else {
            throw Error.invalidPackage
        }
        if let fragment = components.fragment {
            guard
                try snapshotFragmentContainsCredentials(
                    fragment,
                    relativeTo: resolved,
                    depth: depth + 1) == false
            else {
                throw Error.invalidPackage
            }
        }
    }

    private func snapshotFragmentContainsCredentials(
        _ fragment: String,
        relativeTo baseURL: URL,
        depth: Int
    ) throws -> Bool {
        guard depth <= 3,
            let decoded = repeatedlyPercentDecoded(fragment)
        else {
            throw Error.invalidPackage
        }
        let sensitiveNames: Set<String> = [
            "access_key", "access_token", "accesskey", "accesstoken", "api_key",
            "apikey", "authorization", "auth", "bearer", "client_secret", "code",
            "credential", "credentials", "cookie", "jwt", "key", "password",
            "passwd", "secret", "session", "sessionid", "sig", "signature", "token",
        ]
        let sensitiveTokens: Set<String> = [
            "auth", "authorization", "bearer", "code", "credential", "credentials",
            "cookie", "jwt", "key", "password", "passwd", "secret", "session",
            "sessionid", "sig", "signature", "token",
        ]
        let sensitiveValueMarkers: [String] = [
            "access_token", "api_key", "apikey", "authorization", "bearer ",
            "credential", "jwt", "password", "secret", "session=", "token=",
        ]
        let normalized = normalizedQueryName(decoded)
        let tokens = normalized.split(separator: "_").map(String.init)
        let lowercased = decoded.lowercased()
        if sensitiveNames.contains(normalized)
            || tokens.contains(where: sensitiveTokens.contains)
            || sensitiveValueMarkers.contains(where: lowercased.contains)
        {
            return true
        }
        if let pseudoQuery = URLComponents(
            string: "https://fragment.invalid/?\(decoded)"),
            queryContainsCredentials(
                pseudoQuery,
                depth: depth,
                sensitiveNames: sensitiveNames,
                sensitiveTokens: sensitiveTokens,
                sensitiveValueMarkers: sensitiveValueMarkers)
        {
            return true
        }
        let fragmentComponents = URLComponents(string: decoded)
        if fragmentComponents?.scheme != nil
            || decoded.hasPrefix("//")
            || decoded.contains("://")
        {
            do {
                try validateSnapshotURLCandidate(
                    decoded,
                    relativeTo: baseURL,
                    depth: depth)
                return false
            } catch {
                return true
            }
        }
        return false
    }

    private func normalizedQueryName(_ value: String) -> String {
        var result = ""
        var previousWasLowercaseOrDigit = false
        var previousWasSeparator = true
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isUppercase = (65...90).contains(code)
            let isLowercase = (97...122).contains(code)
            let isDigit = (48...57).contains(code)
            if isUppercase {
                if previousWasLowercaseOrDigit && previousWasSeparator == false {
                    result.append("_")
                }
                result.unicodeScalars.append(UnicodeScalar(code + 32)!)
                previousWasLowercaseOrDigit = false
                previousWasSeparator = false
            } else if isLowercase || isDigit {
                result.unicodeScalars.append(scalar)
                previousWasLowercaseOrDigit = true
                previousWasSeparator = false
            } else if previousWasSeparator == false {
                result.append("_")
                previousWasLowercaseOrDigit = false
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func validateRevisionJSON(_ revision: ArticleRevisionRecord) throws {
        let recipe: ArticleEditRecipe
        let overrides: ArticleMetadataOverrides
        do {
            recipe = try JSONDecoder.articleWorkshop.decode(
                ArticleEditRecipe.self,
                from: Data(revision.recipeJSON.utf8))
            overrides = try JSONDecoder.articleWorkshop.decode(
                ArticleMetadataOverrides.self,
                from: Data(revision.metadataOverridesJSON.utf8))
        } catch {
            throw Error.invalidJSON(Field.recipeJSON)
        }
        guard recipe.metadataOverrides == overrides,
            Set(recipe.excludedBlockIDs).count == recipe.excludedBlockIDs.count,
            recipe.excludedBlockIDs.allSatisfy({
                $0.isEmpty == false && $0.utf8.count <= limits.maxScalarBytes
            }),
            [recipe.trimBeforeBlockID, recipe.trimAfterBlockID].allSatisfy({
                guard let value = $0 else { return true }
                return value.isEmpty == false && value.utf8.count <= limits.maxScalarBytes
            })
        else {
            throw Error.invalidJSON(Field.recipeJSON)
        }
        guard
            try canonicalJSONString(recipe, field: Field.recipeJSON)
                == revision.recipeJSON,
            try canonicalJSONString(overrides, field: Field.metadataOverridesJSON)
                == revision.metadataOverridesJSON
        else {
            throw Error.invalidJSON(Field.recipeJSON)
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

    private func validateCoverContentVersion(_ value: String) throws {
        guard value.hasPrefix("sha256:") else {
            throw Error.invalidField(Field.coverContentVersion)
        }
        try validateSHA256(
            String(value.dropFirst("sha256:".count)),
            field: Field.coverContentVersion)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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

    private func requireCanonicalJSONString(
        _ value: String,
        field: String
    ) throws -> String {
        let canonical = try canonicalJSONString(value, field: field)
        guard value == canonical else {
            throw Error.invalidJSON(field)
        }
        return value
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
        _ = try validatePackageDirectory(packageDirectory)
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
            _ = try validatePackageArchive(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func validatePackageDirectory(
        _ directory: URL
    ) throws -> [ArticleCloudCaptureAssetDescriptor] {
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
        var imageBytes = 0
        var paths: [String] = []
        var packageAssets: [ArticleCloudCaptureAssetDescriptor] = []
        for case let url as URL in enumerator {
            let relativePath =
                String(url.path.dropFirst(directory.path.count + 1))
            guard
                isBoundedRelativePath(relativePath)
            else {
                throw Error.invalidPackage
            }
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            guard values.isSymbolicLink != true else { throw Error.unsafeFile }
            guard values.isDirectory != true else { throw Error.invalidPackage }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw Error.unsafeFile
            }
            guard total <= limits.maxPackageBytes - size
            else {
                throw Error.packageTooLarge
            }
            total += size
            paths.append(relativePath)
            if let image = try captureImageMember(for: relativePath) {
                guard size <= ArticleWorkshopLimits.maxSingleImageBytes,
                    imageBytes <= ArticleWorkshopLimits.maxTotalImageBytes - size
                else {
                    throw Error.packageTooLarge
                }
                imageBytes += size
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard
                    ArticleImageDownloader.validatedImageType(
                        data: data,
                        mimeType: image.mimeType) != nil
                else {
                    throw Error.invalidPackage
                }
                packageAssets.append(
                    ArticleCloudCaptureAssetDescriptor(
                        path: relativePath,
                        sha256: sha256(data),
                        mediaType: image.mimeType))
            }
        }
        try validateCapturePackageMembers(paths)
        return packageAssets.sorted { $0.path < $1.path }
    }

    private func validatePackageArchive(
        _ url: URL
    ) throws -> [ArticleCloudCaptureAssetDescriptor] {
        try validateRegularFile(url, maximumBytes: limits.maxPackageBytes)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw Error.invalidPackage
        }
        var total: UInt64 = 0
        var imageBytes: UInt64 = 0
        var paths: Set<String> = []
        var packageAssets: [ArticleCloudCaptureAssetDescriptor] = []
        for entry in archive {
            guard isSafeArchivePath(entry.path) else {
                throw Error.invalidPackage
            }
            guard paths.insert(entry.path).inserted else { throw Error.invalidPackage }
            guard entry.type == .file else { throw Error.invalidPackage }
            guard
                entry.uncompressedSize <= UInt64(limits.maxPackageBytes),
                total <= UInt64(limits.maxPackageBytes) - entry.uncompressedSize
            else {
                throw Error.packageTooLarge
            }
            total += entry.uncompressedSize
            if let image = try captureImageMember(for: entry.path) {
                guard
                    entry.uncompressedSize
                        <= UInt64(ArticleWorkshopLimits.maxSingleImageBytes),
                    imageBytes
                        <= UInt64(ArticleWorkshopLimits.maxTotalImageBytes)
                        - entry.uncompressedSize
                else {
                    throw Error.packageTooLarge
                }
                imageBytes += entry.uncompressedSize
                var data = Data()
                do {
                    _ = try archive.extract(entry) { chunk in
                        data.append(chunk)
                    }
                } catch {
                    throw Error.invalidPackage
                }
                guard
                    ArticleImageDownloader.validatedImageType(
                        data: data,
                        mimeType: image.mimeType) != nil
                else {
                    throw Error.invalidPackage
                }
                packageAssets.append(
                    ArticleCloudCaptureAssetDescriptor(
                        path: entry.path,
                        sha256: sha256(data),
                        mediaType: image.mimeType))
            }
        }
        try validateCapturePackageMembers(Array(paths))
        return packageAssets.sorted { $0.path < $1.path }
    }

    private func extractPackageArchive(_ url: URL, to directory: URL) throws {
        _ = try validatePackageArchive(url)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw Error.invalidPackage
        }
        for entry in archive {
            guard isSafeArchivePath(entry.path) else { throw Error.invalidPackage }
            guard entry.type == .file else { throw Error.invalidPackage }
            let destination = directory.appending(path: entry.path)
            let root = directory.standardizedFileURL
            guard destination.standardizedFileURL.deletingLastPathComponent() == root else {
                throw Error.invalidPackage
            }
            _ = try archive.extract(entry, to: destination)
        }
    }

    /// Capture package v1 associates the producer's flat, contiguous image
    /// files with snapshot.json by directory membership. The snapshot does not
    /// yet carry explicit local-asset descriptors, so no other path is
    /// authorized by inference.
    private func validateCapturePackageMembers(_ paths: [String]) throws {
        guard paths.count <= ArticleWorkshopLimits.maxImages + 1,
            paths.filter({ $0 == "snapshot.json" }).count == 1
        else {
            throw Error.invalidPackage
        }
        var imageIndices: Set<Int> = []
        for path in paths where path != "snapshot.json" {
            guard let image = try captureImageMember(for: path),
                imageIndices.insert(image.index).inserted
            else {
                throw Error.invalidPackage
            }
        }
        guard imageIndices == Set(0..<imageIndices.count) else {
            throw Error.invalidPackage
        }
    }

    private func captureImageMember(
        for path: String
    ) throws -> (index: Int, mimeType: String)? {
        if path == "snapshot.json" { return nil }
        guard path.hasPrefix("image-"),
            path.contains("/") == false
        else {
            throw Error.invalidPackage
        }
        let fileExtension: String
        let mimeType: String
        if path.hasSuffix(".jpg") {
            fileExtension = "jpg"
            mimeType = "image/jpeg"
        } else if path.hasSuffix(".png") {
            fileExtension = "png"
            mimeType = "image/png"
        } else {
            throw Error.invalidPackage
        }
        let rawIndex =
            path
            .dropFirst("image-".count)
            .dropLast(fileExtension.count + 1)
        guard let index = Int(rawIndex),
            String(index) == rawIndex,
            index >= 0,
            index < ArticleWorkshopLimits.maxImages,
            path == "image-\(index).\(fileExtension)"
        else {
            throw Error.invalidPackage
        }
        return (index, mimeType)
    }

    private func validateInstalledCapture(
        at directory: URL,
        expected capture: ArticleCaptureRecord
    ) throws {
        _ = try validatePackageDirectory(directory)
        let snapshot = directory.appending(path: "snapshot.json")
        try validateRegularFile(
            snapshot,
            maximumBytes: min(
                limits.maxPackageBytes,
                ArticleWorkshopLimits.maxEnvelopeBytes))
        let data = try Data(
            contentsOf: snapshot,
            options: [.mappedIfSafe])
        guard data.count <= ArticleWorkshopLimits.maxEnvelopeBytes,
            SHA256.hash(data: data)
                .map({ String(format: "%02x", $0) })
                .joined() == capture.contentSHA256
        else {
            throw Error.invalidPackage
        }
        let envelope: ArticleCaptureEnvelope
        do {
            envelope = try JSONDecoder.articleWorkshop.decode(
                ArticleCaptureEnvelope.self,
                from: data)
        } catch {
            throw Error.invalidPackage
        }
        try validateSnapshotJSONSchema(data)
        try validateTrustedSnapshotEncoding(envelope, originalData: data)
        guard envelope.schemaVersion == 1,
            envelope.captureID.uuidString == capture.id,
            envelope.method == capture.captureMethod,
            envelope.payload.sourceURL == capture.sourceURL,
            envelope.payload.canonicalURL == capture.canonicalURL,
            capture.title == (envelope.payload.title ?? "Untitled article"),
            capture.author == envelope.payload.byline,
            capture.siteName == envelope.payload.siteName,
            capture.language == envelope.payload.language,
            capture.publishedAt == envelope.payload.publishedTime,
            capture.capturedAt == envelope.capturedAt.ISO8601Format(),
            capture.extractorVersion == "schema-\(envelope.schemaVersion)",
            ArticleContentState(rawValue: capture.contentState) != nil
        else {
            throw Error.invalidPackage
        }
        try validateProvenanceURL(envelope.payload.sourceURL, field: Field.sourceURL)
        if let canonicalURL = envelope.payload.canonicalURL {
            try validateProvenanceURL(canonicalURL, field: Field.canonicalURL)
        }
        guard let sourceURL = URL(string: envelope.payload.sourceURL) else {
            throw Error.invalidPackage
        }
        for imageURL in envelope.payload.imageURLs {
            try validateSnapshotURLCandidate(imageURL, relativeTo: sourceURL)
        }
        try validateSnapshotURLAttributes(
            envelope.payload.contentXHTML,
            sourceURL: envelope.payload.sourceURL)
        let sanitized: ArticleSnapshot
        do {
            sanitized = try ArticleBlockSanitizer().sanitize(envelope: envelope)
        } catch {
            throw Error.invalidPackage
        }
        guard sanitized.captureID.uuidString == capture.id,
            sanitized.metadata.title == normalizedEnvelopeText(envelope.payload.title)
                ?? "Untitled article",
            sanitized.metadata.author == normalizedEnvelopeText(envelope.payload.byline),
            sanitized.metadata.siteName == normalizedEnvelopeText(envelope.payload.siteName),
            sanitized.metadata.language == normalizedEnvelopeText(envelope.payload.language),
            sanitized.metadata.publishedTime
                == normalizedEnvelopeText(envelope.payload.publishedTime),
            sanitized.contentState != .captureFailed || capture.contentState == "captureFailed"
        else {
            throw Error.invalidPackage
        }
        do {
            _ = try JSONDecoder().decode([String].self, from: Data(capture.warningsJSON.utf8))
        } catch {
            throw Error.invalidPackage
        }
    }

    private func isSafeArchivePath(_ path: String) -> Bool {
        guard path.isEmpty == false, path.hasPrefix("/") == false else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let pathComponents =
            components.last?.isEmpty == true ? components.dropLast() : components[...]
        return path.utf8.count <= 1_024
            && pathComponents.count <= 24
            && pathComponents.allSatisfy {
                $0.isEmpty == false
                    && $0 != "."
                    && $0 != ".."
                    && $0.utf8.count <= 255
            }
    }

    private func validateSnapshotJSONSchema(_ data: Data) throws {
        let allowedRoot: Set<String> = [
            "schemaVersion", "captureID", "capturedAt", "method",
            "sourceApplication", "payload",
        ]
        let requiredRoot: Set<String> = [
            "schemaVersion", "captureID", "capturedAt", "method", "payload",
        ]
        let allowedPayload: Set<String> = [
            "sourceURL", "canonicalURL", "title", "byline", "siteName",
            "language", "publishedTime", "excerpt", "contentXHTML",
            "textContent", "imageURLs",
        ]
        let requiredPayload: Set<String> = [
            "sourceURL", "contentXHTML", "textContent", "imageURLs",
        ]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys).isSubset(of: allowedRoot),
            requiredRoot.isSubset(of: Set(root.keys)),
            let payload = root["payload"] as? [String: Any],
            Set(payload.keys).isSubset(of: allowedPayload),
            requiredPayload.isSubset(of: Set(payload.keys))
        else {
            throw Error.invalidPackage
        }
    }

    private func validateTrustedSnapshotEncoding(
        _ envelope: ArticleCaptureEnvelope,
        originalData: Data
    ) throws {
        let formats: [JSONEncoder.OutputFormatting] = [
            [],
            [.sortedKeys],
            [.withoutEscapingSlashes],
            [.sortedKeys, .withoutEscapingSlashes],
        ]
        for format in formats {
            let encoder = JSONEncoder.articleWorkshop
            encoder.outputFormatting = format
            if try encoder.encode(envelope) == originalData {
                return
            }
        }
        throw Error.invalidPackage
    }

    private func isBoundedRelativePath(_ path: String) -> Bool {
        isSafeArchivePath(path)
    }

    private func normalizedEnvelopeText(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed =
            value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
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
                Field.packageAssetsJSON,
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
                Field.coverContentVersion,
            ]
        }
        if let unknown = record.allKeys().first(where: { allowed.contains($0) == false }) {
            throw Error.prohibitedField(unknown)
        }
    }
}

nonisolated private enum SnapshotURLAttributeSemantics {
    case single
    case whitespaceList
    case srcset
    case css
}

nonisolated private final class SnapshotURLAttributeCollector:
    NSObject, XMLParserDelegate
{
    struct Attribute {
        let name: String
        let value: String
    }

    static let semantics: [String: SnapshotURLAttributeSemantics] = [
        "about": .single,
        "action": .single,
        "archive": .whitespaceList,
        "background": .single,
        "cite": .single,
        "classid": .single,
        "clip-path": .css,
        "codebase": .single,
        "cursor": .css,
        "data": .single,
        "dynsrc": .single,
        "fill": .css,
        "filter": .css,
        "formaction": .single,
        "href": .single,
        "icon": .single,
        "imagesrcset": .srcset,
        "itemid": .single,
        "longdesc": .single,
        "lowsrc": .single,
        "manifest": .single,
        "marker": .css,
        "marker-end": .css,
        "marker-mid": .css,
        "marker-start": .css,
        "mask": .css,
        "ping": .whitespaceList,
        "poster": .single,
        "profile": .single,
        "resource": .single,
        "src": .single,
        "srcset": .srcset,
        "stroke": .css,
        "style": .css,
        "usemap": .single,
        "xlink:href": .single,
        "xml:base": .single,
    ]

    private(set) var attributes: [Attribute] = []
    private(set) var containsRejectedSyntax = false
    private var styleDepth = 0
    private var styleText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localElementName =
            elementName.split(separator: ":").last.map(String.init)?
            .lowercased() ?? elementName.lowercased()
        if localElementName == "meta",
            attributeDict.first(where: {
                $0.key.caseInsensitiveCompare("http-equiv") == .orderedSame
            })?.value.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("refresh") == .orderedSame
        {
            containsRejectedSyntax = true
        }
        if localElementName == "style" {
            guard styleDepth == 0 else {
                containsRejectedSyntax = true
                return
            }
            styleDepth = 1
            styleText = ""
        } else if styleDepth > 0 {
            styleDepth += 1
        }
        for (rawName, value) in attributeDict {
            let name = rawName.lowercased()
            if Self.semantics[name] != nil {
                attributes.append(Attribute(name: name, value: value))
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleDepth > 0 {
            styleText += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        guard styleDepth > 0 else { return }
        guard let string = String(data: cdataBlock, encoding: .utf8) else {
            containsRejectedSyntax = true
            return
        }
        styleText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard styleDepth > 0 else { return }
        styleDepth -= 1
        if styleDepth == 0 {
            let localElementName =
                elementName.split(separator: ":").last.map(String.init)?
                .lowercased() ?? elementName.lowercased()
            guard localElementName == "style" else {
                containsRejectedSyntax = true
                styleText = ""
                return
            }
            attributes.append(Attribute(name: "style", value: styleText))
            styleText = ""
        }
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        if target.caseInsensitiveCompare("xml-stylesheet") == .orderedSame {
            containsRejectedSyntax = true
        }
    }
}
