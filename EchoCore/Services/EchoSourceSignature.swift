// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// A device-independent hash of an EPUB's *canonical* content — the fields
/// that describe what a block says, not where or how a particular device
/// currently stores/displays it. Two imports of the same book produce the
/// same signature even when local audiobook ids, chapter assignments,
/// hidden/visible state, and asset paths differ across devices.
///
/// Used to join a portable study deck (built from one device's
/// `export-blocks` output) back to the same book re-imported on another
/// device, without relying on any device-local identifier.
nonisolated struct EchoSourceSignature: Codable, Equatable, Sendable {
    /// Bump when the canonical field set or hashing scheme changes.
    static let currentAlgorithm = "echo-canonical-blocks-v1"

    let algorithm: String
    let value: String

    /// Hash the canonical content of `records`. Order-independent: records are
    /// re-sorted by `sequenceIndex`, tie-broken by portable block id, before
    /// hashing, so the same block set produces the same signature regardless
    /// of the order it's supplied in.
    static func make(records: [EPubBlockRecord]) -> Self {
        let ordered = records.sorted {
            if $0.sequenceIndex != $1.sequenceIndex {
                return $0.sequenceIndex < $1.sequenceIndex
            }
            return AlignmentSidecar.portableSuffix(of: $0.id)
                < AlignmentSidecar.portableSuffix(of: $1.id)
        }
        var encoder = CanonicalSourceEncoder()
        encoder.append(currentAlgorithm)
        encoder.append(String(ordered.count))
        for record in ordered {
            encoder.append(AlignmentSidecar.portableSuffix(of: record.id))
            encoder.append(record.blockKind)
            encoder.append(record.text ?? "")
            encoder.append(record.isFrontMatter ? "1" : "0")
            encoder.append(String(record.sequenceIndex))
            encoder.append(record.wordCount.map(String.init) ?? "null")
        }
        let digest = SHA256.hash(data: encoder.data)
        return Self(
            algorithm: currentAlgorithm,
            value: "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

/// Length-prefixed field concatenation so no combination of canonical field
/// values (e.g. text containing the framing separator) can produce the same
/// byte stream as a different set of fields.
private nonisolated struct CanonicalSourceEncoder {
    private(set) var data = Data()

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
