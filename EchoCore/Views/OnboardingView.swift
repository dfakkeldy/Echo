// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// First-launch guide for Echo's core study workflow.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            TabView {
                ForEach(Self.workflowSteps) { step in
                    OnboardingStepPage(step: step)
                }
            }
            .tabViewStyle(.page)
            .navigationTitle("Welcome to Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: finish)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Get Started", action: finish)
                }
            }
        }
    }

    private func finish() {
        hasSeenOnboarding = true
        dismiss()
    }

    private static let workflowSteps: [OnboardingStep] = [
        .init(
            id: "import",
            title: "Import",
            detail:
                "Choose an audiobook or standalone EPUB. Add the matching EPUB to unlock searchable text.",
            systemImage: "square.and.arrow.down",
            tint: .blue
        ),
        .init(
            id: "align",
            title: "Align",
            detail:
                "Search for a paragraph, play the narration, then align the text when the words match.",
            systemImage: "link",
            tint: .green
        ),
        .init(
            id: "capture",
            title: "Capture",
            detail:
                "Bookmark important moments, attach notes or voice memos, and save passages for later.",
            systemImage: "bookmark.fill",
            tint: .orange
        ),
        .init(
            id: "review",
            title: "Review",
            detail:
                "Turn saved passages into flashcards and review them with spaced repetition.",
            systemImage: "brain",
            tint: .teal
        ),
    ]
}
