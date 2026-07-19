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

    @Test func anchorsWithWordsRoundTrip() throws {
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s4-b12", timestamp: 123.45, confidence: 1.0,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "The", start: 123.45, end: 123.61),
                    AlignmentSidecar.Anchor.Word(word: "quick", start: 123.61, end: 123.89),
                ]),
            AlignmentSidecar.Anchor(blockId: "s4-b13", timestamp: 130.0, confidence: 1.0),
        ]
        let data = try AlignmentSidecar.encode(anchors)
        let decoded = try AlignmentSidecar.decode(data)
        #expect(decoded == anchors)
        #expect(decoded[0].words?.count == 2)
        #expect(
            decoded[0].words?[1]
                == AlignmentSidecar.Anchor.Word(
                    word: "quick", start: 123.61, end: 123.89))
        #expect(decoded[1].words == nil)
    }

    /// Backward compatibility: a legacy anchors-only sidecar (no `words` key)
    /// must still decode, with `words == nil`.
    @Test func decodesLegacyAnchorsOnlySidecar() throws {
        let legacy = Data(
            """
            [{"blockId":"s0-b1","confidence":1,"timestamp":75}]
            """.utf8)
        let decoded = try AlignmentSidecar.decode(legacy)
        #expect(decoded.count == 1)
        #expect(decoded[0].blockId == "s0-b1")
        #expect(decoded[0].timestamp == 75)
        #expect(decoded[0].words == nil)
        #expect(decoded[0].sourceBlockIdentity == nil)
    }

    /// Forward compatibility: an old Echo build's decoder (which knows nothing
    /// about `words`) must decode a new word-bearing sidecar, ignoring the
    /// unknown key — modeled here with the legacy anchor shape.
    @Test func legacyDecoderIgnoresWordsKeyInNewSidecar() throws {
        struct LegacyAnchor: Codable {
            let blockId: String
            let timestamp: TimeInterval
            let confidence: Double?
        }
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s4-b12", timestamp: 12.0, confidence: 1.0,
                words: [AlignmentSidecar.Anchor.Word(word: "Hello", start: 12.0, end: 12.4)])
        ]
        let data = try AlignmentSidecar.encode(anchors)
        let decoded = try JSONDecoder().decode([LegacyAnchor].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded[0].blockId == "s4-b12")
        #expect(decoded[0].timestamp == 12.0)
    }

    /// Anchors without words must keep the legacy JSON shape: no `words` key at
    /// all (a `"words":null` would be new-shape noise in hand-diffed sidecars).
    @Test func encodingWithoutWordsOmitsTheKey() throws {
        let data = try AlignmentSidecar.encode([
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 1.5, confidence: 1.0)
        ])
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("words"))
    }

    /// The record-based export path (Mac batch aligner) stays anchors-only.
    @Test func recordEncodeStaysAnchorsOnly() throws {
        let data = try AlignmentSidecar.encode([
            anchor(blockID: "epub-file:///Users/dan/Books/HC/-s2-b1", time: 12.5)
        ])
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("words"))
        #expect(try AlignmentSidecar.decode(data).first?.words == nil)
    }

    @Test func sourceIdentityIsDevicePortableAndContentSensitive() {
        let mac = sourceBlock(audiobookID: "file:///Users/dan/Book/", text: "Same text")
        let phone = sourceBlock(audiobookID: "file:///var/mobile/Book/", text: "Same text")
        let revised = sourceBlock(audiobookID: "file:///var/mobile/Book/", text: "Revised text")

        #expect(
            AlignmentSidecar.sourceIdentity(for: mac) == AlignmentSidecar.sourceIdentity(for: phone)
        )
        #expect(
            AlignmentSidecar.sourceIdentity(for: mac)
                != AlignmentSidecar.sourceIdentity(for: revised))
    }

    @Test func sourceIdentityGoldenDigestFreezesCanonicalEncoding() {
        let block = sourceBlock(audiobookID: "golden", text: "Canonical source")

        #expect(
            AlignmentSidecar.sourceIdentity(for: block)
                == "155e723d158fb286eb3440c9012c014cffd10130cce6613e07342916246d95d1"
        )
    }

    @Test func sourceIdentityIgnoresImportAndNarrationDerivedFields() {
        let parsed = sourceBlock(audiobookID: "book", text: "A promoted section title")
        var imported = parsed
        imported.blockKind = EPubBlockRecord.Kind.heading.rawValue
        imported.chapterIndex = 4
        imported.narrationText = "An FM-refined section title."

        #expect(
            AlignmentSidecar.sourceIdentity(for: parsed)
                == AlignmentSidecar.sourceIdentity(for: imported))
    }

    @Test func sourceIdentityIgnoresReconstructedHTMLAttributeOrder() {
        var firstParse = sourceBlock(audiobookID: "book", text: "Canonical source")
        firstParse.htmlContent = "<span class=\"term\" id=\"anchor\">Canonical source</span>"
        var secondParse = firstParse
        secondParse.htmlContent = "<span id=\"anchor\" class=\"term\">Canonical source</span>"

        #expect(
            AlignmentSidecar.sourceIdentity(for: firstParse)
                == AlignmentSidecar.sourceIdentity(for: secondParse)
        )
    }

    @Test func mixedModernSidecarRejectsResolvableAnchorWithoutIdentity() {
        let first = sourceBlock(audiobookID: "book", text: "First")
        var second = sourceBlock(audiobookID: "book", text: "Second")
        second.id = "epub-book-s2-b2"
        second.blockIndex = 2
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s2-b1",
                timestamp: 0,
                confidence: 1,
                sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: first)
            ),
            AlignmentSidecar.Anchor(
                blockId: "s2-b2",
                timestamp: 1,
                confidence: 1
            ),
        ]

        #expect(
            AlignmentSidecar.sourceValidation(for: anchors, blocks: [first, second])
                == .identityMissing(blockID: "s2-b2")
        )
    }

    @Test func recordEncodeWithSourceBlocksAttachesIdentity() throws {
        let block = sourceBlock(audiobookID: "ab", text: "Current source")
        let data = try AlignmentSidecar.encode(
            [anchor(blockID: block.id, time: 12.5)],
            sourceBlocks: [block]
        )

        let decoded = try AlignmentSidecar.decode(data)
        #expect(decoded.first?.sourceBlockIdentity == AlignmentSidecar.sourceIdentity(for: block))
    }

    @Test func sidecarURLIsEpubSibling() {
        let epub = URL(fileURLWithPath: "/x/Books/My Book.epub")
        #expect(
            AlignmentSidecar.url(forEPUB: epub).lastPathComponent == "My Book.alignment.json")
    }

    @Test func documentFinalizerFindsCaseInsensitiveAlignmentSidecarSibling() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("alignment-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let epub = folder.appendingPathComponent("findable.epub")
        let sidecar = folder.appendingPathComponent("Findable.alignment.json")
        try Data().write(to: epub)
        try Data("[]".utf8).write(to: sidecar)

        #expect(DocumentImportFinalizer.alignmentSidecarURL(for: epub) == sidecar)
    }

    private func sourceBlock(audiobookID: String, text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-\(audiobookID)-s2-b1",
            audiobookID: audiobookID,
            spineHref: "chapter.xhtml",
            spineIndex: 2,
            blockIndex: 1,
            sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text,
            chapterIndex: 0,
            isHidden: false
        )
    }
}
