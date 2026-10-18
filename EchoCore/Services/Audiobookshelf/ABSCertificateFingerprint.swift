// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Security

/// SHA-256 fingerprints of TLS leaf certificates, plus display formatting.
/// The decision logic lives in `ABSServerTrustEvaluator`; this is the thin cert-I/O + string layer.
// `nonisolated` because these are pure cert/string helpers called from the
// `nonisolated` `URLSessionDelegate` trust callback; under the project's MainActor
// default isolation they would otherwise be inferred `@MainActor`.
nonisolated enum ABSCertificateFingerprint {
    /// Lowercase, unseparated hex of a SHA-256 digest (the canonical stored/compared form).
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Colon-grouped uppercase pairs for human display, e.g. "AB:12:CD".
    static func display(_ hex: String) -> String {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count, by: 2).map { i -> String in
            String(chars[i..<min(i + 2, chars.count)]).uppercased()
        }.joined(separator: ":")
    }

    /// SHA-256 (lowercase hex) of the DER-encoded leaf certificate in `trust`, or nil if the chain
    /// is empty. Uses `SecTrustCopyCertificateChain` (the iOS 15+/macOS 12+ replacement for the
    /// deprecated `SecTrustGetCertificateAtIndex`).
    static func leafSHA256(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return hex(SHA256.hash(data: der))
    }
}
