// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import CryptoKit
import Foundation
import GRDB
import os.log

/// Syncs community-contributed alignment anchors via CloudKit.
///
/// Shared anchors intentionally use the public CloudKit database because this is
/// community reuse/discovery data, not a user's private device-sync state. Treat
/// public records as untrusted input: bound payload sizes, attribute uploads with
/// a hashed CloudKit user record name, throttle local writes, and validate before
/// merging or importing.
@MainActor
final class CloudKitSyncService {
    private let logger = Logger(category: "CloudKitSyncService")
    private let container = CKContainer(identifier: "iCloud.com.echo.audiobooks")
    private var publicDatabase: CKDatabase { container.publicCloudDatabase }

    // Dependencies
    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    // MARK: - Constants

    private nonisolated static let sharedAlignmentRecordType = "SharedAlignment"
    nonisolated static let maxAnchorCount = 2_000
    nonisolated static let maxAnchorPayloadBytes = 512 * 1_024
    nonisolated static let uploadThrottleInterval: TimeInterval = 12 * 60
    private nonisolated static let uploadDefaultsPrefix =
        "CloudKitSyncService.lastUpload.SharedAlignment"

    /// Generates a deterministic, collision-resistant record name from audiobook metadata.
    /// Uses SHA-256 so the same title+author+duration produces the same ID across devices and launches.
    private nonisolated static func recordName(title: String, author: String, duration: Double)
        -> String
    {
        let composite = "\(title)|\(author)|\(Int(duration))"
        let hash = SHA256.hash(data: Data(composite.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func uploaderHash(forUserRecordName userRecordName: String) -> String {
        let hash = SHA256.hash(data: Data(userRecordName.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func uploadDefaultsKey(recordName: String) -> String {
        "\(uploadDefaultsPrefix).\(recordName)"
    }

    nonisolated static func canUpload(
        lastUploadDate: Date?,
        now: Date = .now,
        minimumInterval: TimeInterval = uploadThrottleInterval
    ) -> Bool {
        guard let lastUploadDate else { return true }
        return now.timeIntervalSince(lastUploadDate) >= minimumInterval
    }

    nonisolated static func uploadableAnchors(_ anchors: [AlignmentAnchorRecord])
        -> [AlignmentAnchorRecord]
    {
        anchors.filter { $0.source != AlignmentAnchorRecord.Source.synthesized.rawValue }
    }

    nonisolated static func publicPayloadAnchor(from anchor: AlignmentAnchorRecord)
        -> CloudKitPublicAnchor
    {
        CloudKitPublicAnchor(
            blockID: AlignmentSidecar.portableSuffix(of: anchor.epubBlockID),
            audioTime: anchor.audioTime,
            audioEndTime: anchor.audioEndTime,
            anchorKind: anchor.anchorKind,
            source: anchor.source)
    }

    nonisolated static func encodedAnchorPayload(
        forUpload anchors: [AlignmentAnchorRecord],
        maxAnchorCount: Int = maxAnchorCount,
        maxPayloadBytes: Int = maxAnchorPayloadBytes
    ) throws -> String {
        let uploadable = uploadableAnchors(anchors)
        let publicAnchors = uploadable.map(publicPayloadAnchor)
        guard uploadable.count <= maxAnchorCount else {
            throw CloudKitAnchorPayloadError.tooManyAnchors(
                count: uploadable.count, max: maxAnchorCount)
        }

        let payloadData = try JSONEncoder().encode(publicAnchors)
        guard payloadData.count <= maxPayloadBytes else {
            throw CloudKitAnchorPayloadError.payloadTooLarge(
                bytes: payloadData.count, max: maxPayloadBytes)
        }
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw CloudKitAnchorPayloadError.invalidUTF8
        }
        return payloadString
    }

    nonisolated static func validatedDecodedAnchors(
        _ payload: String?,
        audiobookID: String,
        maxAnchorCount: Int = maxAnchorCount,
        maxPayloadBytes: Int = maxAnchorPayloadBytes
    ) throws -> [AlignmentAnchorRecord] {
        guard let payload else { return [] }
        guard payload.utf8.count <= maxPayloadBytes else {
            throw CloudKitAnchorPayloadError.payloadTooLarge(
                bytes: payload.utf8.count, max: maxPayloadBytes)
        }
        guard let data = payload.data(using: .utf8) else {
            throw CloudKitAnchorPayloadError.invalidUTF8
        }

        let publicAnchors: [CloudKitPublicAnchor]
        do {
            publicAnchors = try JSONDecoder().decode([CloudKitPublicAnchor].self, from: data)
        } catch {
            let legacyAnchors = try JSONDecoder().decode([AlignmentAnchorRecord].self, from: data)
            publicAnchors = legacyAnchors.map(publicPayloadAnchor)
        }

        guard publicAnchors.count <= maxAnchorCount else {
            throw CloudKitAnchorPayloadError.tooManyAnchors(
                count: publicAnchors.count, max: maxAnchorCount)
        }
        return publicAnchors.map { $0.alignmentAnchor(audiobookID: audiobookID) }
    }

    nonisolated static func semanticallyValidRemoteAnchors(
        _ anchors: [AlignmentAnchorRecord],
        duration: Double,
        localBlockIDs: Set<String>
    ) -> [AlignmentAnchorRecord] {
        anchors.filter { anchor in
            guard anchor.source != AlignmentAnchorRecord.Source.synthesized.rawValue else {
                return false
            }
            guard localBlockIDs.contains(anchor.epubBlockID) else {
                return false
            }
            guard anchor.audioTime >= 0 && anchor.audioTime <= duration else {
                return false
            }
            if let endTime = anchor.audioEndTime {
                guard endTime >= 0 && endTime <= duration && endTime >= anchor.audioTime else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Anchor merge (§6.1)

    /// Decodes a CloudKit anchor payload string, tolerating missing/malformed data.
    nonisolated static func decodeAnchors(
        _ payload: String?,
        audiobookID: String
    ) -> [AlignmentAnchorRecord] {
        (try? validatedDecodedAnchors(payload, audiobookID: audiobookID)) ?? []
    }

    /// Higher rank = more trustworthy: human-made anchors beat imported beat machine.
    nonisolated static func sourceRank(_ source: String) -> Int {
        switch AlignmentAnchorRecord.Source(rawValue: source) {
        case .moveToNow, .searchResult, .chapterBoundary: return 2
        case .imported: return 1
        case .autoAlignment, .continuousBackground, .synthesized, .transcriptAlignment, nil:
            return 0
        }
    }

    /// Unions local and sanitized remote anchors by `epubBlockID`. When both sides
    /// anchored the same block, keeps the higher-ranked source; ties go to local
    /// (the uploader's current view).
    nonisolated static func mergeAnchors(
        local: [AlignmentAnchorRecord], remote: [AlignmentAnchorRecord]
    ) -> [AlignmentAnchorRecord] {
        var byBlock: [String: AlignmentAnchorRecord] = [:]
        for anchor in remote { byBlock[anchor.epubBlockID] = anchor }
        for anchor in local {
            if let existing = byBlock[anchor.epubBlockID],
                sourceRank(existing.source) > sourceRank(anchor.source)
            {
                continue
            }
            byBlock[anchor.epubBlockID] = anchor
        }
        return Array(byBlock.values)
    }

    /// Uploads manual alignment anchors for a specific audiobook to the public CloudKit database.
    func uploadAnchors(audiobookID: String, title: String, author: String, duration: Double)
        async throws -> CloudKitAnchorUploadResult
    {
        let recordName = Self.recordName(title: title, author: author, duration: duration)
        let recordID = CKRecord.ID(recordName: recordName)

        guard canUpload(recordName: recordName) else {
            logger.info("Skipped CloudKit anchor upload because the local rate limit is active.")
            return .rateLimited
        }

        // Fetch anchors
        let anchors = try await db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("source") != "synthesized")
                .fetchAll(db)
        }

        guard !anchors.isEmpty else {
            logger.info("No anchors to upload for CloudKit record \(recordName, privacy: .public).")
            return .noUploadableAnchors
        }

        let payloadString = try Self.encodedAnchorPayload(forUpload: anchors)
        let uploaderHash = try await currentUploaderHash()

        let record = CKRecord(recordType: Self.sharedAlignmentRecordType, recordID: recordID)

        record["audiobookTitle"] = title as CKRecordValue
        record["audiobookAuthor"] = author as CKRecordValue
        record["audioDuration"] = duration as CKRecordValue
        record["anchorsPayload"] = payloadString as CKRecordValue
        record["uploaderHash"] = uploaderHash as CKRecordValue
        record["lastUploaderHash"] = uploaderHash as CKRecordValue

        do {
            _ = try await publicDatabase.save(record)
            markUploadCompleted(recordName: recordName)
            logger.info(
                "Successfully uploaded \(anchors.count) anchors to CloudKit record \(recordName, privacy: .public)."
            )
            return .uploaded(anchorCount: anchors.count)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Merge instead of overwrite: the record name is a deterministic hash
            // of title+author+duration, so every user of this book writes the SAME
            // public record. Overwriting would clobber the community's anchors
            // (CODE_AUDIT.md §6.1). First sanitize untrusted remote anchors, then
            // union by block, preferring human anchors.
            let existingRecord = try await publicDatabase.record(for: recordID)
            let remoteAnchors = Self.decodeAnchors(
                existingRecord["anchorsPayload"] as? String, audiobookID: audiobookID)
            let localBlockIDs = try await fetchLocalBlockIDs(for: audiobookID)
            let sanitizedRemoteAnchors = Self.semanticallyValidRemoteAnchors(
                remoteAnchors, duration: duration, localBlockIDs: localBlockIDs)
            if sanitizedRemoteAnchors.count < remoteAnchors.count {
                logger.warning(
                    "Dropped \(remoteAnchors.count - sanitizedRemoteAnchors.count) untrusted remote anchor(s) before CloudKit merge."
                )
            }
            let merged = Self.mergeAnchors(local: anchors, remote: sanitizedRemoteAnchors)
            let uploadableMerged = Self.uploadableAnchors(merged)
            let mergedString = try Self.encodedAnchorPayload(forUpload: uploadableMerged)
            existingRecord["anchorsPayload"] = mergedString as CKRecordValue
            existingRecord["lastUploaderHash"] = uploaderHash as CKRecordValue
            _ = try await publicDatabase.save(existingRecord)
            markUploadCompleted(recordName: recordName)
            logger.info(
                "Merged \(anchors.count) local + \(sanitizedRemoteAnchors.count) remote -> \(uploadableMerged.count) anchors for CloudKit record \(recordName, privacy: .public)."
            )
            return .merged(
                localAnchorCount: anchors.count,
                remoteAnchorCount: sanitizedRemoteAnchors.count,
                uploadedAnchorCount: uploadableMerged.count)
        } catch {
            logger.error("Failed to upload anchors: \(error.localizedDescription)")
            throw error
        }
    }

    /// Downloads alignment anchors from the public CloudKit database if a match is found.
    func downloadAnchors(audiobookID: String, title: String, author: String, duration: Double)
        async throws -> [AlignmentAnchorRecord]
    {
        let recordID = CKRecord.ID(
            recordName: Self.recordName(title: title, author: author, duration: duration))
        let record: CKRecord
        do {
            record = try await publicDatabase.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            logger.info("No shared alignment found for deterministic CloudKit anchor record.")
            return []
        } catch {
            logger.error("Failed to fetch record: \(error.localizedDescription)")
            throw error
        }

        guard let payloadString = record["anchorsPayload"] as? String else {
            return []
        }

        let anchors: [AlignmentAnchorRecord]
        do {
            anchors = try Self.validatedDecodedAnchors(payloadString, audiobookID: audiobookID)
        } catch {
            logger.warning(
                "Rejected untrusted CloudKit anchor payload: \(error.localizedDescription)"
            )
            return []
        }

        let localBlockIDs = try await fetchLocalBlockIDs(for: audiobookID)
        let validAnchors = Self.semanticallyValidRemoteAnchors(
            anchors, duration: duration, localBlockIDs: localBlockIDs)

        if validAnchors.count < anchors.count {
            logger.warning(
                "Filtered out \(anchors.count - validAnchors.count) untrusted anchor(s) from downloaded payload"
            )
        }

        // Map the validated anchors to this specific local audiobookID
        let localizedAnchors = validAnchors.map { anchor in
            var updated = anchor
            updated.audiobookID = audiobookID
            updated.source = AlignmentAnchorRecord.Source.imported.rawValue
            return updated
        }

        logger.info("Successfully downloaded \(localizedAnchors.count) anchors from CloudKit.")
        return localizedAnchors
    }

    private func currentUploaderHash() async throws -> String {
        let userRecordID = try await container.userRecordID()
        return Self.uploaderHash(forUserRecordName: userRecordID.recordName)
    }

    private func canUpload(recordName: String, now: Date = .now) -> Bool {
        let key = Self.uploadDefaultsKey(recordName: recordName)
        let timestamp = UserDefaults.standard.double(forKey: key)
        let lastUploadDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        return Self.canUpload(lastUploadDate: lastUploadDate, now: now)
    }

    private func markUploadCompleted(recordName: String, now: Date = .now) {
        UserDefaults.standard.set(
            now.timeIntervalSince1970, forKey: Self.uploadDefaultsKey(recordName: recordName))
    }

    private func fetchLocalBlockIDs(for audiobookID: String) async throws -> Set<String> {
        try await db.read { db in
            try String.fetchSet(
                db, sql: "SELECT id FROM epub_block WHERE audiobook_id = ?",
                arguments: [audiobookID])
        }
    }
}

enum CloudKitAnchorUploadResult: Equatable, Sendable {
    case uploaded(anchorCount: Int)
    case merged(localAnchorCount: Int, remoteAnchorCount: Int, uploadedAnchorCount: Int)
    case noUploadableAnchors
    case rateLimited
}

nonisolated struct CloudKitPublicAnchor: Codable, Equatable, Sendable {
    var blockID: String
    var audioTime: TimeInterval
    var audioEndTime: TimeInterval?
    var anchorKind: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case audioTime = "audio_time"
        case audioEndTime = "audio_end_time"
        case anchorKind = "anchor_kind"
        case source
    }

    func alignmentAnchor(audiobookID: String) -> AlignmentAnchorRecord {
        let localBlockID = AlignmentSidecar.localBlockID(blockID, audiobookID: audiobookID)
        return AlignmentAnchorRecord(
            id: "cloudkit-\(AlignmentSidecar.portableSuffix(of: blockID))",
            audiobookID: audiobookID,
            epubBlockID: localBlockID,
            audioTime: audioTime,
            audioEndTime: audioEndTime,
            anchorKind: anchorKind,
            source: source,
            note: nil,
            createdAt: nil,
            modifiedAt: nil)
    }
}

enum CloudKitAnchorPayloadError: LocalizedError, Equatable, Sendable {
    case tooManyAnchors(count: Int, max: Int)
    case payloadTooLarge(bytes: Int, max: Int)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .tooManyAnchors(let count, let max):
            "CloudKit anchor payload contains \(count) anchors; maximum is \(max)."
        case .payloadTooLarge(let bytes, let max):
            "CloudKit anchor payload is \(bytes) bytes; maximum is \(max)."
        case .invalidUTF8:
            "CloudKit anchor payload is not valid UTF-8."
        }
    }
}
