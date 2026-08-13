// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum FeedbackCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case bugReport
    case featureRequest
    case general
    case praise
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bugReport: return String(localized: "Bug Report")
        case .featureRequest: return String(localized: "Feature Request")
        case .general: return String(localized: "General Feedback")
        case .praise: return String(localized: "Praise")
        case .other: return String(localized: "Other")
        }
    }

    var prompt: String {
        switch self {
        case .bugReport: return String(localized: "Something is not working correctly")
        case .featureRequest: return String(localized: "Suggest a feature or improvement")
        case .general: return String(localized: "Share what is on your mind")
        case .praise: return String(localized: "Tell us what is working well")
        case .other: return String(localized: "Anything else about Echo")
        }
    }

    var systemImage: String {
        switch self {
        case .bugReport: return "ladybug"
        case .featureRequest: return "lightbulb"
        case .general: return "text.bubble"
        case .praise: return "heart"
        case .other: return "ellipsis.circle"
        }
    }
}
