// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

nonisolated struct DockStatusFeedback: Equatable, Sendable {
    let message: String
    let systemImage: String
    let isSuccess: Bool

    init(result: MarkPassageResult) {
        switch result {
        case .saved:
            message = String(localized: "Passage marked")
            systemImage = "checkmark.circle.fill"
            isSuccess = true
        case .unavailable, .failed:
            message = String(localized: "Couldn't mark passage")
            systemImage = "exclamationmark.circle.fill"
            isSuccess = false
        }
    }
}

struct DockStatusFeedbackCapsule: View {
    let feedback: DockStatusFeedback

    var body: some View {
        Label(feedback.message, systemImage: feedback.systemImage)
            .font(.headline)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
