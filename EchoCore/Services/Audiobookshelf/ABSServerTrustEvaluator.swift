// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, testable trust decision for an Audiobookshelf TLS server-trust challenge.
/// No `Security`/`Foundation` cert I/O here — the caller (`ABSServerTrustDelegate`) extracts the
/// inputs and applies the result. This is the unit-tested heart of self-signed cert pinning.
// `nonisolated` because this evaluator is a pure value type consumed from the
// `nonisolated` `URLSessionDelegate` trust callback. Under the project's MainActor
// default isolation the struct (and its nested `Decision`'s synthesized `Equatable`
// conformance) would otherwise be inferred `@MainActor`, which the synchronous
// nonisolated delegate cannot touch.
nonisolated struct ABSServerTrustEvaluator: Sendable {
    enum Decision: Equatable, Sendable { case useDefault, accept, reject }

    /// Lowercased host of the server's configured base URL.
    let expectedHost: String
    /// Trusted leaf-cert SHA-256 (lowercase hex) for this server, or nil if nothing is pinned yet.
    let pinnedSHA256: String?

    init(expectedHost: String, pinnedSHA256: String?) {
        self.expectedHost = expectedHost.lowercased()
        self.pinnedSHA256 = pinnedSHA256
    }

    func decide(
        isServerTrust: Bool,
        challengeHost: String,
        defaultTrustSucceeded: Bool,
        leafSHA256: String?
    ) -> Decision {
        // Only ever special-case server-trust challenges for the exact host the user configured.
        // A redirect/CDN host (or a non-server-trust method) validates normally.
        guard isServerTrust, challengeHost.lowercased() == expectedHost else { return .useDefault }
        // Cert already chains to a system-trusted CA → no pin needed (user installed a real cert).
        if defaultTrustSucceeded { return .useDefault }
        // Untrusted cert on our host: accept iff we hold a pin and the leaf matches it exactly.
        if let pinnedSHA256, let leafSHA256, leafSHA256 == pinnedSHA256 { return .accept }
        return .reject
    }
}
