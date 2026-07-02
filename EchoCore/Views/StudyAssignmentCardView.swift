// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

struct StudyAssignmentCardView: View {
    let entry: StudyQueueEntry
    let isRevealed: Bool
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onGrade: (ReviewGrade) -> Void
    var onSkip: (() -> Void)? = nil
    var needsAttention: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AssignmentHeaderView(entry: entry, title: labelTitle, icon: labelIcon)

            if entry.flashcard.cardType == StudyFlashcardType.imageAssignment {
                StudyLocalImageView(path: imagePath, accessibilityLabel: entry.flashcard.frontText)
                    .frame(maxHeight: 260)
            }

            if isVocabulary {
                if let context = VocabularyCardContext.sentence(
                    fromMediaJSON: entry.flashcard.mediaJSON)
                {
                    Text(context)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button(
                isVocabulary ? "Play in context" : "Play Assignment",
                systemImage: "play.circle.fill", action: onPlay
            )
            .buttonStyle(.borderedProminent)

            if needsAttention {
                Label(
                    "Could not auto-play this chapter today. Play it manually.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if isRevealed {
                if isVocabulary {
                    #if os(iOS)
                        if DictionaryLookupPresenter.hasDefinition(for: entry.flashcard.frontText) {
                            Button(
                                "Look Up \"\(entry.flashcard.frontText)\"",
                                systemImage: "book.circle"
                            ) {
                                DictionaryLookupPresenter.present(term: entry.flashcard.frontText)
                            }
                            .buttonStyle(.bordered)
                        }
                    #endif
                } else {
                    Text(entry.flashcard.backText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                StudyAssignmentGradeButtons(
                    grades: StudyAssignmentGradePolicy.choices(for: entry.flashcard.cardType),
                    onGrade: onGrade)
                if let onSkip {
                    Button("Skip - I know this chapter", systemImage: "forward.end", action: onSkip)
                        .buttonStyle(.bordered)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                Button("Review Retention", systemImage: "checkmark.circle", action: onReveal)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private var isVocabulary: Bool {
        entry.flashcard.cardType == StudyFlashcardType.vocabulary
    }

    private var labelTitle: String {
        switch entry.flashcard.cardType {
        case StudyFlashcardType.imageAssignment: "Image Assignment"
        case StudyFlashcardType.vocabulary: "Vocabulary"
        default: "Listening Assignment"
        }
    }

    private var labelIcon: String {
        switch entry.flashcard.cardType {
        case StudyFlashcardType.imageAssignment: "photo"
        case StudyFlashcardType.vocabulary: "character.book.closed"
        default: "headphones"
        }
    }

    private var imagePath: String? {
        guard entry.flashcard.cardType == StudyFlashcardType.imageAssignment else { return nil }
        guard let mediaJSON = entry.flashcard.mediaJSON,
            let data = mediaJSON.data(using: .utf8),
            let media = try? JSONDecoder().decode(StudyCardMedia.self, from: data)
        else {
            return nil
        }
        return media.imagePath
    }
}

private struct AssignmentHeaderView: View {
    let entry: StudyQueueEntry
    let title: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.flashcard.frontText)
                .font(.title3)
                .bold()
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StudyAssignmentGradeButtons: View {
    let grades: [ReviewGrade]
    let onGrade: (ReviewGrade) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(grades, id: \.self) { grade in
                Button(grade.label) {
                    onGrade(grade)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct StudyLocalImageView: View {
    let path: String?
    let accessibilityLabel: String

    var body: some View {
        #if canImport(UIKit)
            if let path, let image = UIImage(contentsOfFile: path) {
                StudyDecoratedImageView(
                    image: Image(uiImage: image), accessibilityLabel: accessibilityLabel)
            } else {
                StudyUnavailableImagePlaceholder()
            }
        #elseif canImport(AppKit)
            if let path, let image = NSImage(contentsOfFile: path) {
                StudyDecoratedImageView(
                    image: Image(nsImage: image), accessibilityLabel: accessibilityLabel)
            } else {
                StudyUnavailableImagePlaceholder()
            }
        #else
            StudyUnavailableImagePlaceholder()
        #endif
    }
}

private struct StudyDecoratedImageView: View {
    let image: Image
    let accessibilityLabel: String

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(Text(accessibilityLabel))
    }
}

private struct StudyUnavailableImagePlaceholder: View {
    var body: some View {
        Image(systemName: "photo")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(.secondary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(Text("Image unavailable"))
    }
}
