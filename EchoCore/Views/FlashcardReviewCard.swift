// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct FlashcardReviewCard: View {
    let frontText: String
    let backText: String
    let onGrade: (Int) -> Void

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 0) {
            // Card face — Button for proper accessibility, keyboard nav, and hit-testing.
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isRevealed.toggle()
                }
            } label: {
                VStack {
                    if isRevealed {
                        Text(backText)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(20)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .background(.purple.opacity(0.08))
                            .transition(.flip)
                    } else {
                        Text(frontText)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding(20)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.white.opacity(0.05))
                                    .stroke(.secondary.opacity(0.2))
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? Text("Answer") : Text("Question: \(frontText)"))
            .accessibilityHint(isRevealed ? String(localized: "Tap to show question") : String(localized: "Tap to reveal answer"))

            // Grade buttons (shown after reveal)
            if isRevealed {
                HStack(spacing: 8) {
                    ForEach(ReviewGrade.allCases, id: \.self) { grade in
                        Button {
                            onGrade(grade.rawValue)
                        } label: {
                            Text(grade.label)
                                .font(.caption)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(color(for: grade).opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityLabel(Text(grade.label))
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding(16)
    }

    private func color(for grade: ReviewGrade) -> Color {
        switch grade {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }
}

extension AnyTransition {
    static let flip: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.95)),
        removal: .opacity.combined(with: .scale(scale: 1.05))
    )
}
