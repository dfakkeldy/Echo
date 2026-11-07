// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Sheet showing the audiobook's chapter list for "Align to Chapter."
///
/// A tap selects a chapter and closes the sheet, so rows carry no push
/// chevron. The playing chapter is marked by one signal, a checkmark, and
/// scrolled into view on open, so the list says "you are here".
struct ChapterPickerSheet: View {
    let chapters: [Chapter]
    let onSelect: (Chapter) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

    var body: some View {
        CoverThemedSheet(theme: model.coverTheme) {
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    row(for: chapter)
                        .listRowBackground(CoverSheetRowBackground())
                }
                .onAppear {
                    if let current = currentChapter {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            // Inline, like Table of Contents and Reader Settings, so the
            // rows sit close to the grabber.
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentChapter: Chapter? {
        guard let index = model.currentChapterIndex else { return nil }
        return chapters.first { $0.index == index }
    }

    private func row(for chapter: Chapter) -> some View {
        let isCurrent = chapter.index == model.currentChapterIndex
        let defaultTitle = String(localized: "Chapter \(chapter.index + 1)")
        let displayTitle = (chapter.title ?? defaultTitle)
            .applyingChapterTruncation(enabled: settings.truncateChapterNamesEnabled)
        let start = formatTime(chapter.startSeconds)

        return Button {
            onSelect(chapter)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(start)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(displayTitle))
        .accessibilityValue(Text("Starts at \(start)"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Row card for lists inside a `CoverThemedSheet`: a translucent veil of the
/// sheet's own colour instead of an opaque system-grey card, so rows sit on
/// the tonal ramp as one material. Lighter on the immersive dark ramp, a
/// soft white panel on the pale light ramp.
struct CoverSheetRowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.white.opacity(colorScheme == .dark ? 0.07 : 0.55)
    }
}
