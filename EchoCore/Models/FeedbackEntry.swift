// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct FeedbackEntry: Equatable, Sendable {
    var category: FeedbackCategory
    var rating: Int
    var message: String
    var diagnostics: FeedbackDiagnostics?
    var createdAt: Date

    init(
        category: FeedbackCategory,
        rating: Int,
        message: String,
        diagnostics: FeedbackDiagnostics?,
        createdAt: Date = .now
    ) {
        self.category = category
        self.rating = min(max(rating, 1), 5)
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.diagnostics = diagnostics
        self.createdAt = createdAt
    }

    var suggestsAppStoreReview: Bool {
        rating >= 4
    }

    var suggestsSupportFollowUp: Bool {
        rating <= 2
    }

    var emailSubject: String {
        "Echo Feedback: \(category.title)"
    }

    var emailBody: String {
        """
        Category: \(category.title)
        Rating: \(rating)/5
        Sent: \(createdAt.formatted(date: .abbreviated, time: .shortened))

        \(message)

        ---
        \(diagnostics?.formattedString ?? String(localized: "Device diagnostics not included."))
        """
    }
}
