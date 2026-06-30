// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Result of an attempted contribution send.
enum ContributionTransportResult: Equatable {
    /// The consent gate refused — the user has not opted in.
    case blockedNoConsent
    /// Consent was granted but the live channel does not exist yet; nothing was
    /// transmitted. Carries a human-readable reason for the deferral.
    case deferred(reason: String)
}

/// DEFERRED / SKELETON (design doc Section 6 M5, Decision D7). The live contribution
/// channel is intentionally NOT implemented: it requires an approved transport
/// design and real fix data from M3/M4 first. This stub exists so the consent
/// invariant is enforced and testable today, and so the codebase has one
/// obvious, inert place the real transport will later replace.
///
/// Hard constraints the eventual implementation MUST keep:
/// - It MUST NOT reuse `CloudKitSyncService` / the public alignment-anchor DB
///   (whose trust posture stays intact — design doc Section 6 caveat).
/// - It MUST consult `ContributionConsentGate` before doing anything.
/// - It MUST send only `PronunciationContributionPayload` (term-level fields).
///
/// This type imports no networking framework on purpose.
struct DeferredContributionTransport {
    func send(
        _ payloads: [PronunciationContributionPayload],
        consent: ContributionConsent
    ) -> ContributionTransportResult {
        guard ContributionConsentGate.allows(consent) else {
            return .blockedNoConsent
        }
        // Consent granted, but there is no live channel. Do not transmit.
        return .deferred(
            reason: "Contribution transport is not yet implemented; \(payloads.count) "
                + "payload(s) retained locally and not transmitted.")
    }
}
