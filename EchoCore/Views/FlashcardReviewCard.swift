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
                            .background(.white.opacity(0.05))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.2)))
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
                    ForEach(0..<6) { grade in
                        Button {
                            onGrade(grade)
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(grade)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(gradeLabel(grade))
                                        .font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(gradeColor(grade).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityLabel(Text("Grade \(grade): \(gradeLabel(grade))"))
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding(16)
    }

    private func gradeLabel(_ grade: Int) -> String {
        switch grade {
        case 0: return "Again"
        case 1, 2: return "Hard"
        case 3, 4: return "Good"
        case 5: return "Easy"
        default: return ""
        }
    }

    private func gradeColor(_ grade: Int) -> Color {
        switch grade {
        case 0: return .red
        case 1, 2: return .orange
        case 3, 4: return .green
        case 5: return .blue
        default: return .gray
        }
    }
}

extension AnyTransition {
    static let flip: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.95)),
        removal: .opacity.combined(with: .scale(scale: 1.05))
    )
}
