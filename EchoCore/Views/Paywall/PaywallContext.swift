// SPDX-License-Identifier: GPL-3.0-or-later
/// What triggered the paywall — for the contextual subheadline.
enum PaywallContext {
    case flashcardCap
    case narrationCap
    case transcripts
    case insights
    case export
    case absSync
    case settings

    var subheadline: String {
        switch self {
        case .flashcardCap:
            "You've filled your 20 free cards — Echo Pro makes them unlimited."
        case .narrationCap:
            "Free narration covers one chapter per book. Echo Pro unlocks the whole library."
        case .transcripts:
            "Transcript overlays are part of Echo Pro."
        case .insights:
            "Insights are part of Echo Pro."
        case .export:
            "Study export is part of Echo Pro."
        case .absSync:
            "Offline downloads & sync are part of Echo Pro."
        case .settings:
            "Turn listening into learning."
        }
    }
}
