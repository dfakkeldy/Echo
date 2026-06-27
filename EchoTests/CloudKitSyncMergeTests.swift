// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Tests the pure anchor-merge/payload logic that replaced the public-DB
/// overwrite (CODE_AUDIT.md §6.1). No live CloudKit required.
struct CloudKitSyncMergeTests {

    private func anchor(_ block: String, _ source: String, time: Double = 1.0)
        -> AlignmentAnchorRecord
    {
        AlignmentAnchorRecord(
            id: "\(block)-\(source)", audiobookID: "book", epubBlockID: block,
            audioTime: time, anchorKind: "point", source: source)
    }

    @Test func mergeUnionsDisjointBlocks() {
        let merged = CloudKitSyncService.mergeAnchors(
            local: [anchor("A", "autoAlignment")],
            remote: [anchor("B", "autoAlignment")])
        #expect(Set(merged.map(\.epubBlockID)) == ["A", "B"])
    }

    @Test func mergePrefersHumanOverMachineOnConflict() {
        let merged = CloudKitSyncService.mergeAnchors(
            local: [anchor("A", "autoAlignment", time: 99)],
            remote: [anchor("A", "moveToNow", time: 10)])
        #expect(merged.count == 1)
        #expect(merged.first?.source == "moveToNow")
        #expect(merged.first?.audioTime == 10)
    }

    @Test func mergeLocalHumanUpgradesRemoteMachine() {
        let merged = CloudKitSyncService.mergeAnchors(
            local: [anchor("A", "searchResult", time: 20)],
            remote: [anchor("A", "autoAlignment", time: 10)])
        #expect(merged.count == 1)
        #expect(merged.first?.source == "searchResult")
        #expect(merged.first?.audioTime == 20)
    }

    /// The core regression: a device with one anchor must never wipe a larger
    /// community payload.
    @Test func mergeNeverShrinksRemotePayload() {
        let remote = ["A", "B", "C", "D"].map { anchor($0, "moveToNow") }
        let merged = CloudKitSyncService.mergeAnchors(
            local: [anchor("A", "autoAlignment")], remote: remote)
        #expect(merged.count >= remote.count)
        #expect(Set(merged.map(\.epubBlockID)) == ["A", "B", "C", "D"])
    }

    @Test func decodeToleratesMissingOrMalformed() {
        #expect(CloudKitSyncService.decodeAnchors(nil, audiobookID: "book").isEmpty)
        #expect(CloudKitSyncService.decodeAnchors("{ not json", audiobookID: "book").isEmpty)
    }

    @Test func decodeRoundTripsEncodedAnchors() throws {
        let original = [
            anchor("epub-book-s0-b0", "moveToNow", time: 5),
            anchor("epub-book-s0-b1", "autoAlignment", time: 9),
        ]
        let payload = try CloudKitSyncService.encodedAnchorPayload(forUpload: original)
        let decoded = CloudKitSyncService.decodeAnchors(payload, audiobookID: "book")
        #expect(Set(decoded.map(\.epubBlockID)) == ["epub-book-s0-b0", "epub-book-s0-b1"])
    }

    @Test func publicUploadPayloadDoesNotExposeLocalIdentifiers() throws {
        let audiobookID = "file:///Users/dan/Library/Group Containers/private/Book"
        let fullBlockID = "epub-\(audiobookID)-s1-b2"
        let payload = try CloudKitSyncService.encodedAnchorPayload(forUpload: [
            AlignmentAnchorRecord(
                id: "secret-anchor", audiobookID: audiobookID, epubBlockID: fullBlockID,
                audioTime: 42, anchorKind: "point", source: "moveToNow")
        ])

        #expect(!payload.contains("audiobook_id"))
        #expect(!payload.contains("epub_block_id"))
        #expect(!payload.contains(audiobookID))
        #expect(!payload.contains(fullBlockID))
        #expect(payload.contains("s1-b2"))

        let decoded = CloudKitSyncService.decodeAnchors(payload, audiobookID: audiobookID)
        #expect(decoded.first?.audiobookID == audiobookID)
        #expect(decoded.first?.epubBlockID == fullBlockID)
    }

    @Test func uploadPayloadExcludesSynthesizedAnchors() throws {
        let payload = try CloudKitSyncService.encodedAnchorPayload(forUpload: [
            anchor("A", "moveToNow", time: 5),
            anchor("B", "synthesized", time: 9),
        ])

        let decoded = CloudKitSyncService.decodeAnchors(payload, audiobookID: "book")
        #expect(decoded.count == 1)
        #expect(decoded.first?.epubBlockID == "epub-book-A")
        #expect(decoded.first?.source == "moveToNow")
    }

    @Test func uploadPayloadRejectsTooManyAnchors() {
        let anchors = (0...10).map {
            anchor("block-\($0)", "moveToNow")
        }

        #expect {
            _ = try CloudKitSyncService.encodedAnchorPayload(forUpload: anchors, maxAnchorCount: 10)
        } throws: { error in
            guard case CloudKitAnchorPayloadError.tooManyAnchors(let count, let max) = error else {
                return false
            }
            return count == 11 && max == 10
        }
    }

    @Test func uploadPayloadRejectsOversizedPayload() {
        let anchors = [anchor(String(repeating: "block", count: 64), "moveToNow")]

        #expect {
            _ = try CloudKitSyncService.encodedAnchorPayload(forUpload: anchors, maxPayloadBytes: 128)
        } throws: { error in
            guard case CloudKitAnchorPayloadError.payloadTooLarge(let bytes, let max) = error else {
                return false
            }
            return bytes > max && max == 128
        }
    }

    @Test func remoteSemanticValidationDropsPollutedPublicAnchors() {
        var badEnd = anchor("bad-end", "moveToNow", time: 10)
        badEnd.audioEndTime = 9
        let anchors = [
            anchor("valid", "moveToNow", time: 10),
            anchor("negative-time", "moveToNow", time: -1),
            anchor("foreign-block", "moveToNow", time: 10),
            badEnd,
            anchor("tts", "synthesized", time: 10),
        ]

        let trusted = CloudKitSyncService.semanticallyValidRemoteAnchors(
            anchors,
            duration: 60,
            localBlockIDs: ["valid", "negative-time", "bad-end", "tts"])

        #expect(trusted.map(\.epubBlockID) == ["valid"])
    }

    @Test func conflictRecoveryCanMergeAfterDroppingPollutedRemoteAnchors() throws {
        let remote = [
            anchor("A", "moveToNow", time: 5),
            anchor("foreign", "moveToNow", time: 5),
            anchor("tts", "synthesized", time: 5),
        ]
        let trustedRemote = CloudKitSyncService.semanticallyValidRemoteAnchors(
            remote, duration: 60, localBlockIDs: ["A", "B"])
        let merged = CloudKitSyncService.mergeAnchors(
            local: [anchor("B", "searchResult", time: 12)], remote: trustedRemote)
        let payload = try CloudKitSyncService.encodedAnchorPayload(forUpload: merged)
        let decoded = CloudKitSyncService.decodeAnchors(payload, audiobookID: "book")

        #expect(Set(decoded.map(\.epubBlockID)) == ["epub-book-A", "epub-book-B"])
        #expect(decoded.allSatisfy { $0.epubBlockID != "epub-book-foreign" })
        #expect(decoded.allSatisfy { $0.source != "synthesized" })
    }

    @Test func decodeRejectsTooManyRemoteAnchors() throws {
        let anchors = (0...CloudKitSyncService.maxAnchorCount).map {
            anchor("block-\($0)", "moveToNow")
        }
        let payload = String(data: try JSONEncoder().encode(anchors), encoding: .utf8)

        #expect(CloudKitSyncService.decodeAnchors(payload, audiobookID: "book").isEmpty)
    }

    @Test func decodeRejectsOversizedRemotePayload() {
        let oversizedPayload = String(
            repeating: "x", count: CloudKitSyncService.maxAnchorPayloadBytes + 1)

        #expect(CloudKitSyncService.decodeAnchors(oversizedPayload, audiobookID: "book").isEmpty)
    }

    @Test func uploadRateLimitAllowsOnlyAfterThrottleInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        let interval = CloudKitSyncService.uploadThrottleInterval

        #expect(CloudKitSyncService.canUpload(lastUploadDate: nil, now: now))
        #expect(
            !CloudKitSyncService.canUpload(
                lastUploadDate: now.addingTimeInterval(-(interval - 1)), now: now))
        #expect(
            CloudKitSyncService.canUpload(
                lastUploadDate: now.addingTimeInterval(-interval), now: now))
    }

    @Test func uploaderHashDoesNotExposeRawUserRecordName() {
        let rawUserRecordName = "_a1b2c3d4e5f6"
        let hash = CloudKitSyncService.uploaderHash(forUserRecordName: rawUserRecordName)
        let hexCharacters = Set("0123456789abcdef")

        #expect(hash != rawUserRecordName)
        #expect(!hash.contains(rawUserRecordName))
        #expect(hash.count == 64)
        #expect(Set(hash).isSubset(of: hexCharacters))
    }
}
