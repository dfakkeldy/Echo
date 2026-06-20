// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NowPlayingTab: View {
    let showsBookSettings: Bool
    let openFolder: () -> Void
    let showHelp: () -> Void
    let showBookSettings: () -> Void
    let showSettings: () -> Void
    let onCreateBookmark: (BookmarkDraft) -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).

    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    @State private var selectedVoice: NarrationVoice = VoiceCatalog.default
    @State private var showingVoicePicker = false
    @State private var showingPlaybackOptions = false
    /// Owns the player-More chapter-navigation sheet binding (WS-C). Kept here,
    /// not on RootTabView, so it cannot collide with the global header sheets.
    @State private var showingChapterPicker = false

    /// The saved voice preference, or the system default on first launch.
    private var preferredVoice: NarrationVoice {
        let savedID = settings.narrationVoiceID
        guard !savedID.isEmpty else { return VoiceCatalog.default }
        return VoiceCatalog.voice(for: VoiceID(savedID)) ?? VoiceCatalog.default
    }

    var body: some View {
        ZStack {
            // 1. ADAPTIVE GRADIENT BACKGROUND (Rendered globally at RootTabView)

            // 2. MAIN LAYOUT STACK
            VStack(spacing: 0) {
                // Flexible top slack — balances the artwork block vertically.
                Spacer(minLength: 0)

                // B. Artwork Component
                artworkView
                    .frame(minHeight: 150, maxHeight: 330)

                // C. Metadata & Typography Area
                metadataArea
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                    .padding(.top, 16)

                // C2. On-device narration — shown whenever the book has EPUB text.
                // The ONNX (CPU) engine runs on every supported device, so
                // `supportsOnDeviceNarration` is always true; it stays in the
                // condition as the single named capability seam (see NarrationCapability).
                if model.hasEPUB && NarrationCapability.supportsOnDeviceNarration {
                    VStack(spacing: 8) {
                        NarrationStatusView(state: model.narrationPlaybackState)
                        if !model.narrationPlaybackState.isRunning {
                            NarrationNudgeView {
                                // Save the voice preference and start narration
                                // directly — no voice picker on the primary path.
                                settings.narrationVoiceID = preferredVoice.id.rawValue
                                model.startNarrationPlayback(voice: preferredVoice)
                            }
                            // Secondary path: choose a different narrator voice.
                            // (The picker's "Start Narration" saves the choice and
                            // re-renders with it.) Without this the picker sheet was
                            // unreachable — narration was locked to the default voice.
                            Button {
                                selectedVoice = preferredVoice
                                showingVoicePicker = true
                            } label: {
                                Label(
                                    "Voice: \(preferredVoice.displayName)",
                                    systemImage: "person.wave.2"
                                )
                                .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityHint("Choose the narrator voice")
                        }
                        // M4B export folded into the global More menu (UnifiedTopHeader)
                        // so it works for imported books too, not just rendered narration.
                    }
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                    .padding(.top, 12)
                }

                // D. Main Scrubber (completely exposed, floating over background)
                // `containerRelativeFrame` (not `.padding`) sets an explicit
                // width: the scrubber's greedy `Slider`/`maxWidth: .infinity`
                // content overflows a padding-reduced proposal back to full
                // bleed, so padding alone left the slider + time labels jammed
                // against the screen edges.
                PlayerScrubberView()
                    .containerRelativeFrame(.horizontal) { width, _ in
                        width - 2 * NowPlayingLayout.horizontalPadding
                    }
                    .tint(model.artworkAccentColor ?? .accentColor)
                    .padding(.vertical, 16)

                // Flexible gap: pins the dock to the bottom and keeps the
                // scrubber clearly above the dock capsule.
                Spacer(minLength: 0)

                // E. Unified Bottom Dock
                if !model.isPlayingVoiceMemo {
                    UnifiedBottomDock(
                        onCreateBookmark: onCreateBookmark,
                        onShowPlaybackOptions: { showingPlaybackOptions = true },
                        onShowChapters: { showingChapterPicker = true },
                        onShowBookmarks: { model.selectedTab = .timeline },
                        onShowSettings: showSettings
                    )
                    .environment(\.showPlaybackOptions, { showingPlaybackOptions = true })
                }
            }
            .ignoresSafeArea(.keyboard)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Reserve room for Row 1 of UnifiedTopHeader (overlaid in RootTabView).
            // Stacks on top of the real status-bar inset, so it's correct on every device.
            // Must equal the header's real height (see `rowOneHeight`).
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: UnifiedTopHeader.rowOneHeight)
            }
            .environment(
                \.font,
                model.resolvedAppFont == SettingsManager.systemFontName
                    ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body)
            )
            .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
            .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
            .allowsHitTesting(!model.isPlayingVoiceMemo)

            // Voice Memo Overlay
            if model.isPlayingVoiceMemo {
                VoiceMemoOverlayView()
            }

        }
        .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .task(id: model.folderURL) {
            // Pre-warm the ANE model compile so the first Listen tap isn't a long
            // stall — only where narration is actually supported (A15+).
            if model.hasEPUB && NarrationCapability.supportsOnDeviceNarration {
                try? await model.narrationTTS.prepare()
            }
        }
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerView(selectedVoice: $selectedVoice) {
                settings.narrationVoiceID = selectedVoice.id.rawValue
                model.startNarrationPlayback(voice: selectedVoice)
            }
        }
        .sheet(isPresented: $showingPlaybackOptions) {
            PlaybackOptionsSheet()
        }
        // Player-More "Chapters" → jump-to-chapter. Reuses the existing
        // ChapterPickerSheet, supplying a seek closure (matches PlaylistView's
        // chapter-row tap: seek to startSeconds + 0.05 to land inside the chapter).
        .sheet(isPresented: $showingChapterPicker) {
            ChapterPickerSheet(chapters: model.chapters) { chapter in
                model.seek(toSeconds: chapter.startSeconds + 0.05)
            }
        }
    }

    // MARK: - Subviews

    private var artworkView: some View {
        Group {
            if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel(Text("Cover of \(model.currentTitle)"))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: 16))
        .padding(.horizontal, NowPlayingLayout.horizontalPadding)
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }

    private var metadataArea: some View {
        VStack(spacing: 5) {
            // Eyebrow: book + author in small caps, tappable → book info (audit B4)
            Button(action: showBookSettings) {
                Text(secondaryLineText)
                    .customFont(.caption, weight: .semibold, appFont: model.resolvedAppFont)
                    .textCase(.uppercase)
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .disabled(model.folderURL == nil)
            .accessibilityLabel(Text("Book info"))
            .accessibilityValue(Text(secondaryLineText))

            // Hero line: chapter-nav chevrons flank the chapter-title marquee.
            // Chevrons reuse skip*Navigation (chapter-aware; falls back to track)
            // so this in-app bar matches the lock screen byte-for-byte. The whole
            // bar is gated on chapters.count >= 2 to mirror `titleText`; a
            // single-chapter / marker-less book renders the bare marquee as before.
            if model.chapters.count >= 2 {
                HStack(spacing: 8) {
                    Button {
                        model.skipBackwardNavigation()
                        Haptic.play(.light)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: chevronWidth, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasPreviousChapter)
                    .accessibilityLabel(Text("Previous chapter"))
                    .accessibilityHint(Text("Jumps to the previous chapter"))

                    MarqueeText(
                        text: titleText,
                        fontStyle: .title3,
                        fontWeight: .bold,
                        appFont: model.resolvedAppFont,
                        foregroundStyle: .primary
                    )
                    .frame(maxWidth: .infinity, alignment: .center)

                    Button {
                        model.skipForwardNavigation()
                        Haptic.play(.light)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: chevronWidth, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasNextChapter)
                    .accessibilityLabel(Text("Next chapter"))
                    .accessibilityHint(Text("Jumps to the next chapter"))
                }
            } else {
                MarqueeText(
                    text: titleText,
                    fontStyle: .title3,
                    fontWeight: .bold,
                    appFont: model.resolvedAppFont,
                    foregroundStyle: .primary
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Helpers

    /// Fixed hit-target width for each chapter-nav chevron. Reserving a constant
    /// width (rather than letting the chevrons share flexible space) keeps the
    /// MarqueeText container-width measurement stable as the bar's disabled
    /// state changes, so a short title is never shifted by a stale width.
    private let chevronWidth: CGFloat = 44

    private var titleText: String {
        model.chapters.count >= 2
            ? (model.currentSubtitle.isEmpty
                ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)")
                : model.currentSubtitle)
            : model.currentTitle
    }

    private var secondaryLineText: String {
        if model.chapters.count >= 2 {
            let bookTitle = model.currentTitle
            let author = authorText
            return author.isEmpty ? bookTitle : "\(bookTitle) • \(author)"
        } else {
            return authorText.isEmpty ? String(localized: "Audiobook") : authorText
        }
    }

    private var authorText: String {
        if let folderURL = model.folderURL {
            let author = folderURL.deletingLastPathComponent().lastPathComponent
            if author != "Developer" && author != "Documents" && !author.isEmpty {
                return author
            }
        }
        return ""
    }

    private func formatHhMm(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60.0)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "\(h)h\(m.formatted(.number.precision(.integerLength(2))))m"
        } else {
            return "\(m)m"
        }
    }

    private func bookProgressParts() -> (elapsed: String, remaining: String) {
        let speed = model.speed > 0 ? Double(model.speed) : 1.0
        let elapsedSeconds = model.cumulativePlaybackTime
        let totalBookDuration =
            model.isMultiM4B ? model.totalBookDuration : (model.durationSeconds ?? 0)
        let scaledElapsed = elapsedSeconds / speed
        let scaledDuration = totalBookDuration / speed
        let scaledRemaining = max(0, scaledDuration - scaledElapsed)
        return (formatHhMm(scaledElapsed), formatHhMm(scaledRemaining))
    }

    private func chapterProgressText() -> String {
        let chapterIndex = (model.currentChapterIndex ?? 0) + 1
        let chapterCount = model.chapters.count
        let parts = bookProgressParts()
        return String(
            localized:
                "Ch \(chapterIndex) of \(chapterCount), \(parts.elapsed) elapsed, \(parts.remaining) remaining"
        )
    }

    private func trackProgressText() -> String {
        let trackIndex = model.currentIndex + 1
        let trackCount = model.tracks.count
        let parts = bookProgressParts()
        return String(
            localized:
                "Track \(trackIndex) of \(trackCount), \(parts.elapsed) elapsed, \(parts.remaining) remaining"
        )
    }
}

/// Shared "glass pill" surface for the Now Playing bottom deck.
private struct PlayerDeckSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
    }
}

extension View {
    fileprivate func playerDeckSurface() -> some View {
        modifier(PlayerDeckSurface())
    }
}
