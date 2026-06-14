import CloudKit
import CryptoKit
import Foundation
import GRDB
import os.log

/// Syncs community-contributed alignment anchors via CloudKit.
///
/// **Security note (§6.4):** The public CloudKit database allows anyone with the
/// container identifier to write arbitrary anchor data. For production, consider:
/// - Switching writes to `privateCloudDatabase` (anchors only visible to owner)
/// - Adding a server-side CKSubscription validation step
/// - Rate-limiting uploads per device (e.g. max 5 uploads/hour)
/// - Validating that anchor timestamps are non-negative and within audiobook duration
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

    /// Generates a deterministic, collision-resistant record name from audiobook metadata.
    /// Uses SHA-256 so the same title+author+duration produces the same ID across devices and launches.
    private nonisolated static func recordName(title: String, author: String, duration: Double)
        -> String
    {
        let composite = "\(title)|\(author)|\(Int(duration))"
        let hash = SHA256.hash(data: Data(composite.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Anchor merge (§6.1)

    /// Decodes a CloudKit anchor payload string, tolerating missing/malformed data.
    nonisolated static func decodeAnchors(_ payload: String?) -> [AlignmentAnchorRecord] {
        guard let payload, let data = payload.data(using: .utf8),
            let anchors = try? JSONDecoder().decode([AlignmentAnchorRecord].self, from: data)
        else { return [] }
        return anchors
    }

    /// Higher rank = more trustworthy: human-made anchors beat imported beat machine.
    nonisolated static func sourceRank(_ source: String) -> Int {
        switch AlignmentAnchorRecord.Source(rawValue: source) {
        case .moveToNow, .searchResult, .chapterBoundary: return 2
        case .imported: return 1
        case .autoAlignment, .continuousBackground, nil: return 0
        }
    }

    /// Unions local and remote anchors by `epubBlockID`. When both sides anchored
    /// the same block, keeps the higher-ranked source; ties go to local (the
    /// uploader's current view). The result always covers every remote block, so
    /// a small local set can never shrink the shared community payload.
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
        async throws
    {
        // Fetch anchors
        let anchors = try await db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == audiobookID)
                .fetchAll(db)
        }

        guard !anchors.isEmpty else {
            logger.info("No anchors to upload for \(title).")
            return
        }

        let encoder = JSONEncoder()
        let payloadData = try encoder.encode(anchors)
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw NSError(
                domain: "CloudKitSync", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode anchors"])
        }

        let recordID = CKRecord.ID(
            recordName: Self.recordName(title: title, author: author, duration: duration))
        let record = CKRecord(recordType: Self.sharedAlignmentRecordType, recordID: recordID)

        record["audiobookTitle"] = title as CKRecordValue
        record["audiobookAuthor"] = author as CKRecordValue
        record["audioDuration"] = duration as CKRecordValue
        record["anchorsPayload"] = payloadString as CKRecordValue

        do {
            _ = try await publicDatabase.save(record)
            logger.info("Successfully uploaded \(anchors.count) anchors for \(title).")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Merge instead of overwrite: the record name is a deterministic hash
            // of title+author+duration, so every user of this book writes the SAME
            // public record. Overwriting would clobber the community's anchors
            // (CODE_AUDIT.md §6.1). Union by block, preferring human anchors; the
            // union never shrinks the payload.
            let existingRecord = try await publicDatabase.record(for: recordID)
            let remoteAnchors = Self.decodeAnchors(existingRecord["anchorsPayload"] as? String)
            let merged = Self.mergeAnchors(local: anchors, remote: remoteAnchors)
            let mergedData = try encoder.encode(merged)
            guard let mergedString = String(data: mergedData, encoding: .utf8) else {
                throw NSError(
                    domain: "CloudKitSync", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to encode merged anchors"])
            }
            existingRecord["anchorsPayload"] = mergedString as CKRecordValue
            _ = try await publicDatabase.save(existingRecord)
            logger.info(
                "Merged \(anchors.count) local + \(remoteAnchors.count) remote -> \(merged.count) anchors for \(title)."
            )
        } catch {
            logger.error("Failed to upload anchors: \(error.localizedDescription)")
            throw error
        }
    }

    /// Downloads alignment anchors from the public CloudKit database if a match is found.
    func downloadAnchors(audiobookID: String, title: String, author: String, duration: Double)
        async throws -> [AlignmentAnchorRecord]
    {
        // Use %@ with NSNumber to avoid floating-point precision loss from %f formatting
        let predicate = NSPredicate(
            format: "audiobookTitle == %@ AND audiobookAuthor == %@ AND audioDuration == %@", title,
            author, NSNumber(value: duration))
        let query = CKQuery(recordType: Self.sharedAlignmentRecordType, predicate: predicate)

        let (matchResults, _) = try await publicDatabase.records(matching: query, resultsLimit: 1)

        guard let firstMatch = matchResults.first else {
            logger.info("No shared alignment found for \(title).")
            return []
        }

        switch firstMatch.1 {
        case .success(let record):
            guard let payloadString = record["anchorsPayload"] as? String,
                let payloadData = payloadString.data(using: .utf8)
            else {
                return []
            }

            let decoder = JSONDecoder()
            let anchors = try decoder.decode([AlignmentAnchorRecord].self, from: payloadData)

            // Validate payload before inserting into local database (§6.4).
            // The public CloudKit database allows anyone with the container
            // identifier to write arbitrary anchor data. Reject anchors whose
            // timestamps are nonsensical relative to the audiobook duration.
            let validAnchors = anchors.filter { anchor in
                guard anchor.audioTime >= 0 && anchor.audioTime <= duration else {
                    logger.warning(
                        "Rejected downloaded anchor \(anchor.id): audioTime \(anchor.audioTime)s outside [0, \(duration)]s"
                    )
                    return false
                }
                if let endTime = anchor.audioEndTime {
                    guard endTime >= 0 && endTime <= duration && endTime >= anchor.audioTime else {
                        logger.warning(
                            "Rejected downloaded anchor \(anchor.id): audioEndTime \(endTime)s invalid for [0, \(duration)]s"
                        )
                        return false
                    }
                }
                return true
            }

            if validAnchors.count < anchors.count {
                logger.warning(
                    "Filtered out \(anchors.count - validAnchors.count) invalid anchor(s) from downloaded payload"
                )
            }

            // Map the validated anchors to this specific local audiobookID
            let localizedAnchors = validAnchors.map { anchor in
                var updated = anchor
                updated.audiobookID = audiobookID
                updated.source = AlignmentAnchorRecord.Source.imported.rawValue
                return updated
            }

            logger.info("Successfully downloaded \(localizedAnchors.count) anchors for \(title).")
            return localizedAnchors

        case .failure(let error):
            logger.error("Failed to fetch record: \(error.localizedDescription)")
            throw error
        }
    }
}
