import Foundation

/// A chime sound used for interval-based reminders.
enum ChimeSound: String, CaseIterable, Identifiable, Sendable {
    case softChime = "soft_chime"
    case gentleTone = "gentle_tone"
    case subtleBell = "subtle_bell"
    case woodTap = "wood_tap"
    case mindfulness = "mindfulness"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .softChime: return "bell"
        case .gentleTone: return "bell.badge"
        case .subtleBell: return "bell.circle"
        case .woodTap: return "hand.tap"
        case .mindfulness: return "sparkles"
        }
    }

    var displayName: String {
        switch self {
        case .softChime: return String(localized: "Soft Chime")
        case .gentleTone: return String(localized: "Gentle Tone")
        case .subtleBell: return String(localized: "Subtle Bell")
        case .woodTap: return String(localized: "Wood Tap")
        case .mindfulness: return String(localized: "Mindfulness")
        }
    }
}
