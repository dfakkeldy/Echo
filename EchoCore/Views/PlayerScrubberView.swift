import SwiftUI

/// Extracted scrubber control that only observes `PlayerModel` via `@Bindable`,
/// isolating the 0.5-second observation updates from the main `ContentView`.
struct PlayerScrubberView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    @State private var scrubFraction: Double = 0.0
    @State private var isScrubbing = false
    @State private var lastSnappedFraction: Double? = nil
    /// Audit B5: tapping the trailing time label toggles remaining ↔ duration,
    /// the standard iOS behavior people already expect.
    @AppStorage("scrubberShowsRemaining") private var showsRemaining = true

    var body: some View {
        if settings.playerLayoutStyle == "compact" {
            HStack(spacing: 12) {
                timeLabel(model.elapsedText, alignment: .leading)
                scrubber
                trailingTimeButton
            }
        } else {
            VStack(spacing: 0) {
                scrubber

                HStack {
                    timeLabel(model.elapsedText, alignment: .leading)
                    Spacer()
                    trailingTimeButton
                }
                .padding(.horizontal, 4) // slight inset so text aligns with the slider thumb visually

                // Audit B5: hairline book track + caption — the "where am I in
                // the whole book" answer, on the same axis as the scrubber.
                if model.chapters.count >= 2 {
                    BookProgressTrack(
                        bookFraction: bookFraction,
                        tickFractions: BookProgressTrackModel.tickFractions(
                            chapters: model.chapters,
                            totalDuration: bookTotalDuration
                        ),
                        accent: model.artworkAccentColor ?? .accentColor
                    )
                    .padding(.top, 9)
                    .padding(.horizontal, 4)

                    Text(BookProgressTrackModel.caption(
                        bookFraction: bookFraction,
                        chapterTitle: currentLogicalChapter?.title,
                        chapterCount: model.chapters.count
                    ))
                    .customFont(.caption2, appFont: model.resolvedAppFont)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var trailingTimeButton: some View {
        Button {
            showsRemaining.toggle()
            Haptic.play(.light)
        } label: {
            timeLabel(showsRemaining ? model.progressText : model.durationText, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(showsRemaining ? "Time remaining" : "Duration"))
        .accessibilityHint(Text("Double tap to toggle"))
    }

    private var bookTotalDuration: Double {
        model.isMultiM4B ? model.totalBookDuration : (model.durationSeconds ?? 0)
    }

    private var bookFraction: Double {
        let total = bookTotalDuration
        guard total > 0 else { return 0 }
        let elapsed: Double
        if model.isMultiM4B {
            let bookOffset = model.m4bBooks.indices.contains(model.currentIndex)
                ? model.m4bBooks[model.currentIndex].cumulativeStartOffset : 0
            elapsed = bookOffset + model.currentPlaybackTime
        } else {
            elapsed = model.currentPlaybackTime
        }
        return min(1, max(0, elapsed / total))
    }

    private var scrubber: some View {
        Slider(
            value: $scrubFraction,
            in: 0...1,
            onEditingChanged: { editing in
                isScrubbing = editing
                if !editing {
                    model.seek(toFraction: scrubFraction)
                }
            }
        )
        .frame(minWidth: Self.minimumScrubberWidth, maxWidth: .infinity)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text("\(model.elapsedText), \(model.progressText)"))
        .onChange(of: scrubFraction) { oldValue, newValue in
            if !isScrubbing {
                // Only sync from external updates when not actively dragging.
                if model.progressFraction != newValue {
                    scrubFraction = model.progressFraction
                }
                return
            }

            guard !model.currentChapterSections.isEmpty, let chapter = currentLogicalChapter else { return }
            let chapterStart = chapter.startSeconds
            let chapterDuration = chapter.endSeconds - chapter.startSeconds
            guard chapterDuration > 0 else { return }

            // Snapping threshold: roughly 10 seconds, clamped between 1% and 5% of the slider.
            let threshold = max(0.01, min(0.05, 10.0 / chapterDuration))

            for section in model.currentChapterSections.dropFirst() {
                let sectionFraction = (section.startSeconds - chapterStart) / chapterDuration
                if abs(newValue - sectionFraction) < threshold {
                    if lastSnappedFraction != sectionFraction {
                        lastSnappedFraction = sectionFraction
                        scrubFraction = sectionFraction
                        Haptic.play(.rigid)
                    }
                    return
                }
            }

            // If the user drags away from the snap point, clear it so it can trigger again later.
            if let snapped = lastSnappedFraction, abs(newValue - snapped) >= threshold {
                lastSnappedFraction = nil
            }
        }
        .onChange(of: model.progressFraction) { _, newValue in
            if !isScrubbing {
                scrubFraction = newValue
            }
        }
        .onAppear {
            scrubFraction = model.progressFraction
        }
        // Overlay the tick marks on the slider rail.  The Canvas is placed as
        // an overlay so it renders on top of the rail colour but behind the
        // thumb — the Slider's own hit-testing takes priority.
        .overlay(alignment: .center) {
            if !model.currentChapterSections.isEmpty,
               let chapter = currentLogicalChapter {
                SectionTickOverlay(
                    sections: model.currentChapterSections,
                    chapterStart: chapter.startSeconds,
                    chapterDuration: chapter.endSeconds - chapter.startSeconds
                )
                .allowsHitTesting(false)
            }
        }
    }

    /// The currently active logical chapter, used to compute section tick fractions.
    private var currentLogicalChapter: Chapter? {
        guard let idx = model.currentChapterIndex,
              model.chapters.indices.contains(idx) else { return nil }
        return model.chapters[idx]
    }

    private func timeLabel(_ text: String, alignment: Alignment) -> some View {
        ScrubberTimeLabel(
            text: text,
            appFont: model.resolvedAppFont,
            alignment: alignment
        )
        .equatable()
    }

    fileprivate static let timeLabelWidth: CGFloat = 54
    private static let minimumScrubberWidth: CGFloat = 210
}

// MARK: - ScrubberTimeLabel

/// POD (Plain Old Data) time label for the scrubber. Conforms to `Equatable`
/// so SwiftUI can use fast `memcmp` diffing — the body only re-evaluates when
/// the formatted text string actually changes, not on every playback tick.
private struct ScrubberTimeLabel: View, Equatable {
    let text: String
    let appFont: String
    let alignment: Alignment

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.appFont == rhs.appFont && lhs.alignment == rhs.alignment
    }

    var body: some View {
        Text(text)
            .customFont(.footnote, appFont: appFont)
            .foregroundStyle(.primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: PlayerScrubberView.timeLabelWidth, alignment: alignment)
    }
}

// MARK: - SectionTickOverlay

/// A `Canvas`-based view that draws hairline vertical tick marks at each
/// sub-section boundary within the current logical chapter.
///
/// Tick positions are computed as fractions of the chapter duration, then
/// mapped to horizontal pixel positions within the slider rail width.
///
/// Uses `GeometryReader` here because the `Slider` rail's actual drawable
/// width (inset by the thumb radius) is not directly available to the
/// overlay — the geometry proxy provides the only reliable measurement
/// for mapping fractional positions to pixel coordinates.
///
/// The view is rendered with `allowsHitTesting(false)` so the `Slider`
/// underneath remains fully interactive.
private struct SectionTickOverlay: View {

    /// The fine-grained sub-section atoms for the current logical chapter.
    let sections: [Chapter]
    /// Absolute start time of the current logical chapter in seconds.
    let chapterStart: Double
    /// Duration of the current logical chapter in seconds.
    let chapterDuration: Double

    /// Maximum number of tick marks to draw.  When there are more sections,
    /// we skip evenly to avoid a cluttered rail.
    private static let maxTicks = 20

    /// Visual constants.
    private static let railHeight: CGFloat = 4
    private static let tickWidth: CGFloat = 1.5
    private static let tickHeightRatio: CGFloat = 2.2  // tick is taller than the rail

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard chapterDuration > 0 else { return }

                // The SwiftUI Slider's rail doesn't start at x=0 — it is inset
                // by roughly half the thumb diameter on each side.  The thumb
                // is ~28 pt wide on iOS, so each edge is inset ~14 pt.
                let thumbRadius: CGFloat = 14
                let railLeft = thumbRadius
                let railWidth = max(1, size.width - 2 * thumbRadius)

                // Build a downsampled list of section START boundaries to mark.
                // We skip index 0 (= chapter start = already at rail origin).
                let candidates = Array(sections.dropFirst())
                let total = candidates.count
                let step = total > Self.maxTicks ? max(1, total / Self.maxTicks) : 1
                let ticked: [Chapter] = stride(from: 0, to: total, by: step).map { candidates[$0] }

                let tickHeight = Self.railHeight * Self.tickHeightRatio
                let midY = size.height / 2

                for section in ticked {
                    // Convert absolute section start to a fraction within the chapter.
                    let fraction = (section.startSeconds - chapterStart) / chapterDuration
                    guard fraction > 0, fraction < 1 else { continue }

                    let x = railLeft + railWidth * fraction

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: midY - tickHeight / 2))
                    path.addLine(to: CGPoint(x: x, y: midY + tickHeight / 2))

                    context.stroke(
                        path,
                        with: .color(.secondary.opacity(0.55)),
                        lineWidth: Self.tickWidth
                    )
                }
            }
        }
    }
}
