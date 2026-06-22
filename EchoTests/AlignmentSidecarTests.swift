// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct AlignmentSidecarTests {

    private func anchor(blockID: String, time: TimeInterval) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: UUID().uuidString, audiobookID: "ab", epubBlockID: blockID,
            audioTime: time, audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
            note: nil, createdAt: "2026-06-21T00:00:00Z", modifiedAt: nil)
    }

    @Test func portableSuffixExtractsTail() {
        #expect(AlignmentSidecar.portableSuffix(of: "epub-file:///Users/x/Book/-s3-b7") == "s3-b7")
        #expect(AlignmentSidecar.portableSuffix(of: "s12-b0") == "s12-b0")
        // A path containing "-s…" that isn't a block suffix must not confuse it.
        #expect(
            AlignmentSidecar.portableSuffix(of: "epub-file:///my-stuff/version-s5/Book/-s0-b4")
                == "s0-b4")
        // No trailing pattern → returned unchanged.
        #expect(AlignmentSidecar.portableSuffix(of: "not-an-id") == "not-an-id")
    }

    @Test func localBlockIDReprefixes() {
        #expect(
            AlignmentSidecar.localBlockID("s3-b7", audiobookID: "file:///iphone/AB/")
                == "epub-file:///iphone/AB/-s3-b7")
    }

    /// The crux: a suffix lifted from a Mac block id rebuilds correctly against a
    /// *different* device's audiobookID — proving cross-device portability.
    @Test func suffixIsDevicePortable() {
        let macID = "epub-file:///Users/dan/Books/HighConflict/-s4-b2"
        let suffix = AlignmentSidecar.portableSuffix(of: macID)
        let phoneAB = "file:///var/mobile/Containers/Data/Application/UUID/ABSLibrary/item42/"
        let rebuilt = AlignmentSidecar.localBlockID(suffix, audiobookID: phoneAB)
        #expect(rebuilt == "epub-\(phoneAB)-s4-b2")
        // localBlockID is idempotent if handed a full id by mistake.
        #expect(
            AlignmentSidecar.localBlockID(macID, audiobookID: phoneAB)
                == "epub-\(phoneAB)-s4-b2")
    }

    @Test func encodeStripsDeviceLocalPrefixAndRoundTrips() throws {
        let anchors = [
            anchor(blockID: "epub-file:///Users/dan/Books/HC/-s2-b1", time: 12.5),
            anchor(blockID: "epub-file:///Users/dan/Books/HC/-s2-b9", time: 30.0),
        ]
        let data = try AlignmentSidecar.encode(anchors)
        let json = String(decoding: data, as: UTF8.self)
        // The device-local path must NOT leak into the sidecar…
        #expect(!json.contains("/Users/dan/"))
        #expect(!json.contains("epub-"))
        // …only the portable suffixes.
        let decoded = try AlignmentSidecar.decode(data)
        #expect(decoded.map(\.blockId) == ["s2-b1", "s2-b9"])
        #expect(decoded.first?.timestamp == 12.5)
    }

    @Test func sidecarURLIsEpubSibling() {
        let epub = URL(fileURLWithPath: "/x/Books/My Book.epub")
        #expect(
            AlignmentSidecar.url(forEPUB: epub).lastPathComponent == "My Book.alignment.json")
    }
}
