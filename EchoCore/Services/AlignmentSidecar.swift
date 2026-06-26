// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The on-disk `alignment.json` sidecar contract — the cross-platform handoff
/// that lets alignment produced on one device (e.g. the macOS batch aligner) be
/// used on another (the user's phone).
///
/// **Why a portable id.** Block ids are `epub-<audiobookID>-s<i>-b<j>` and
/// `audiobookID` is `folderURL.absoluteString`, which differs per device/install
/// (`Shared/EPUBBlockParser.swift`). The `s<i>-b<j>` tail, by contrast, is
/// content-stable — it derives only from EPUB spine/block order, identical on
/// every device that parses the same EPUB via `parseEPUBBlocks`. So the sidecar
/// stores the **portable suffix** and the importer re-prefixes it with the
/// importing device's own `audiobookID`. (Previously the sidecar stored the full
/// device-local id, so a Mac-written sidecar could never resolve on the phone.)
// `nonisolated`: a stateless utility (URL/string/JSON/file helpers, plus the pure
// `Anchor` value type). Under the iOS target's Swift 6 MainActor default isolation
// it would be inferred `@MainActor`, which the `nonisolated` `EPUBSourceAnchorResolver`
// (and other off-actor callers) cannot reach.
nonisolated enum AlignmentSidecar {

    /// One persisted anchor. `blockId` is the portable `s<i>-b<j>` suffix.
    /// `confidence` is unused on ingest and **optional**, so a leaner or
    /// hand-edited sidecar that omits it still decodes — a missing *required*
    /// field would otherwise reject the entire file and silently drop every
    /// anchor (the exact foreign-sidecar case the drop-filter exists to tolerate).
    struct Anchor: Codable, Equatable {
        let blockId: String
        let timestamp: TimeInterval
        let confidence: Double?
    }

    /// The sidecar file sitting next to an EPUB: `<base>.alignment.json`.
    static func url(forEPUB epubURL: URL) -> URL {
        epubURL.deletingPathExtension().appendingPathExtension("alignment.json")
    }

    /// The content-stable `s<i>-b<j>` tail of a block id. Accepts either a full
    /// `epub-<audiobookID>-s<i>-b<j>` id or a bare suffix and returns the suffix;
    /// anything without the trailing pattern is returned unchanged.
    static func portableSuffix(of blockID: String) -> String {
        if let r = blockID.range(of: "s[0-9]+-b[0-9]+$", options: .regularExpression) {
            return String(blockID[r])
        }
        return blockID
    }

    /// Rebuild a device-local block id from a portable suffix and the importing
    /// device's `audiobookID`. Idempotent if given a full id (re-extracts the
    /// suffix first), so a stray legacy full-id value still resolves locally.
    static func localBlockID(_ portable: String, audiobookID: String) -> String {
        "epub-\(audiobookID)-\(portableSuffix(of: portable))"
    }

    /// Serialize anchors to the portable sidecar form (suffix-only block ids).
    static func encode(_ anchors: [AlignmentAnchorRecord]) throws -> Data {
        let exports = anchors.map {
            Anchor(
                blockId: portableSuffix(of: $0.epubBlockID),
                timestamp: $0.audioTime, confidence: 1.0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exports)
    }

    static func decode(_ data: Data) throws -> [Anchor] {
        try JSONDecoder().decode([Anchor].self, from: data)
    }

    /// Write the sidecar next to `epubURL` (`<base>.alignment.json`), atomically.
    @discardableResult
    static func write(_ anchors: [AlignmentAnchorRecord], forEPUB epubURL: URL) throws -> URL {
        let dest = url(forEPUB: epubURL)
        try encode(anchors).write(to: dest, options: .atomic)
        return dest
    }
}
