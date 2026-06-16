// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Full-screen overlay shown when an inline flashcard trigger fires during playback.
/// Pauses the main player, shows the card, and resumes playback on grade or dismiss.
struct FlashcardOverlayView: View {
    let card: Flashcard
    let onGrade: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture { onDismiss() }
                .accessibilityAddTraits(.isButton)

            FlashcardReviewCard(
                frontText: card.frontText,
                backText: card.backText,
                onGrade: { grade in onGrade(grade) }
            )
            .frame(maxWidth: 360)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(40)
        }
    }
}
