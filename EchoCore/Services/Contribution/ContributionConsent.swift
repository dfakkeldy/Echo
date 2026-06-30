// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Records the user's explicit, opt-in decision to contribute term-level
/// pronunciation fixes to the community improvement channel (design doc Section 8 /
/// Decision D7). Default is NOT opted in — contribution is off until the user
/// makes an affirmative choice. This is a pure value type; persistence and the
/// preview/consent UI are deferred (M5 transport is design-only).
struct ContributionConsent: Equatable, Sendable {
    /// True only when the user has affirmatively opted in.
    let isOptedIn: Bool
    /// When the decision was recorded; nil means the user has not decided.
    let decidedAt: Date?

    /// The default: contribution is off, no decision recorded.
    static let notDecided = ContributionConsent(isOptedIn: false, decidedAt: nil)
}

/// The single decision point any contribution transport MUST consult before it
/// considers sending anything. Centralised so the "nothing leaves without
/// explicit consent" invariant has one enforcement site.
enum ContributionConsentGate {
    static func allows(_ consent: ContributionConsent) -> Bool {
        consent.isOptedIn
    }
}
