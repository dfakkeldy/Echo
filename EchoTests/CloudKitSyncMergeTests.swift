import Foundation
import Testing

@testable import Echo

/// Tests the pure anchor-merge logic that replaced the public-DB overwrite
/// (CODE_AUDIT.md §6.1). No live CloudKit required — `mergeAnchors`/`decodeAnchors`
/// are `nonisolated static` pure functions.
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
        #expect(CloudKitSyncService.decodeAnchors(nil).isEmpty)
        #expect(CloudKitSyncService.decodeAnchors("{ not json").isEmpty)
    }

    @Test func decodeRoundTripsEncodedAnchors() throws {
        let original = [anchor("A", "moveToNow", time: 5), anchor("B", "autoAlignment", time: 9)]
        let data = try JSONEncoder().encode(original)
        let payload = String(data: data, encoding: .utf8)
        let decoded = CloudKitSyncService.decodeAnchors(payload)
        #expect(Set(decoded.map(\.epubBlockID)) == ["A", "B"])
    }
}
