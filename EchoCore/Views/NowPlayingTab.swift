// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NowPlayingTab: View {
    let showsBookSettings: Bool
    let openFolder: () -> Void
    let showHelp: () -> Void
    let showBookSettings: () -> Void
    let onConnectServer: () -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).

    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedVoice: NarrationVoice = VoiceCatalog.default
    @State private var showingVoicePicker = false
    @State private var visualListeningViewModel: VisualListeningViewModel?
    @State private var visualListeningSyncPoint: VisualListeningSyncPoint = .midpoint
    @State private var isWideVisualListeningLayout = false

    /// The saved voice preference, or the system default on first launch.
    private var preferredVoice: NarrationVoice {
        let savedID = settings.narrationVoiceID
        guard !savedID.isEmpty else { return VoiceCatalog.default }
        return VoiceCatalog.voice(for: VoiceID(savedID)) ?? VoiceCatalog.default
    }

    var body: some View {
        ZStack {
            // 1. ADAPTIVE GRADIENT BACKGROUND — must live INSIDE this tab's
            // NavigationStack: the stack's UINavigationController paints an
            // opaque systemBackground, so a ramp layered behind the stack (the
            // pre-2026-07 RootTabView arrangement) is invisible and the player
            // reads as plain black/white.
            AdaptiveBackground()

            // 2. MAIN LAYOUT STACK
            Group {
                if model.folderURL == nil {
                    Color.clear
                        .onAppear {
                            if model.selectedTab == .nowPlaying {
                                model.selectedTab = .library
                            }
                        }
                } else {
                    VStack(spacing: 0) {
                        // Flexible top slack — balances the artwork block vertically.
                        Spacer(minLength: 0)

                        if settings.experimentalNowPlayingLayout {
                            ExperimentalNowPlayingView(showBookSettings: showBookSettings)
                        } else if usesWideVisualListeningLayout,
                            let snapshot = activeVisualListeningSnapshot
                        {
                            wideVisualListeningLayout(snapshot: snapshot)
                        } else {
                            compactPlaybackLayout
                        }

                        // Flexible gap above the root-owned bottom deck.
                        Spacer(minLength: 0)
                    }
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(
                    height: settings.experimentalNowPlayingLayout ? 0 : model.bottomInset)
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
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 760 && proxy.size.width > proxy.size.height * 1.05
        } action: { _, newValue in
            isWideVisualListeningLayout = newValue
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .task(id: model.bookIdentityURL) {
            await reloadVisualListeningViewModel()

            // Pre-warm the ANE model compile so the first Listen tap isn't a long
            // stall — only where narration is actually supported (A15+).
            if model.isNarrationBook && NarrationCapability.supportsOnDeviceNarration {
                try? await model.narrationTTS.prepare()
            }
        }
        .onChange(of: model.currentPlaybackTime) { _, newTime in
            updateVisualListeningSnapshot(time: newTime)
        }
        .onChange(of: model.currentIndex) { _, _ in
            updateVisualListeningSnapshot(time: model.currentPlaybackTime)
        }
        .onChange(of: visualListeningSyncPoint) { _, newSyncPoint in
            visualListeningViewModel?.syncPoint = newSyncPoint
            updateVisualListeningSnapshot(time: model.currentPlaybackTime)
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) {
            handleTimelineItemsIngested($0)
        }
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerView(selectedVoice: $selectedVoice) {
                settings.narrationVoiceID = selectedVoice.id.rawValue
                model.startNarrationPlayback(voice: selectedVoice)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var visualListeningOrArtworkView: some View {
        if let snapshot = activeVisualListeningSnapshot {
            VisualListeningStageView(
                snapshot: snapshot,
                syncPoint: $visualListeningSyncPoint,
                appFont: model.resolvedAppFont
            )
            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
        } else {
            artworkView
        }
    }

    private var activeVisualListeningSnapshot: VisualListeningSnapshot? {
        guard visualListeningViewModel?.hasVisualListeningContent == true,
            let snapshot = visualListeningViewModel?.snapshot,
            snapshot.visualCue != nil,
            snapshot.subtitleCue != nil
        else { return nil }
        return snapshot
    }

    private var usesWideVisualListeningLayout: Bool {
        horizontalSizeClass == .regular
            && isWideVisualListeningLayout
            && !dynamicTypeSize.isAccessibilitySize
            && activeVisualListeningSnapshot != nil
    }

    private var compactPlaybackLayout: some View {
        VStack(spacing: 0) {
            // B. Artwork / visual listening component
            visualListeningOrArtworkView
                .frame(minHeight: 150, maxHeight: 360)

            playbackDetailsAndScrubber
        }
    }

    private func wideVisualListeningLayout(snapshot: VisualListeningSnapshot) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VisualListeningStageView(
                snapshot: snapshot,
                syncPoint: $visualListeningSyncPoint,
                appFont: model.resolvedAppFont
            )
            .frame(minWidth: 340, idealWidth: 500, maxWidth: 620, minHeight: 260, maxHeight: 430)

            playbackDetailsAndScrubber(usesContainerRelativeScrubberWidth: false)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
        }
        .padding(.horizontal, NowPlayingLayout.horizontalPadding)
    }

    private var playbackDetailsAndScrubber: some View {
        playbackDetailsAndScrubber(usesContainerRelativeScrubberWidth: true)
    }

    private func playbackDetailsAndScrubber(
        usesContainerRelativeScrubberWidth: Bool
    ) -> some View {
        VStack(spacing: 0) {
            // C. Metadata & Typography Area
            metadataArea
                .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                .padding(.top, 16)

            narrationNudgeSection

            // D. Main Scrubber (completely exposed, floating over background)
            // `containerRelativeFrame` (not `.padding`) sets an explicit
            // width: the scrubber's greedy `Slider`/`maxWidth: .infinity`
            // content overflows a padding-reduced proposal back to full
            // bleed, so padding alone left the slider + time labels jammed
            // against the screen edges.
            scrubberView(usesContainerRelativeWidth: usesContainerRelativeScrubberWidth)
        }
    }

    @ViewBuilder
    private func scrubberView(usesContainerRelativeWidth: Bool) -> some View {
        if usesContainerRelativeWidth {
            PlayerScrubberView()
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(0, width - 2 * NowPlayingLayout.horizontalPadding)
                }
                .tint(model.resolvedThemeTint)
                .padding(.vertical, 16)
        } else {
            PlayerScrubberView()
                .tint(model.resolvedThemeTint)
                .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private var narrationNudgeSection: some View {
        // On-device narration — only for audio-less EPUB books, or books whose
        // tracks are rendered narration cache files. Imported audiobooks with a
        // companion EPUB already have audio, so the "No audiobook" nudge must stay hidden.
        if model.isNarrationBook && NarrationCapability.supportsOnDeviceNarration {
            VStack(spacing: 8) {
                NarrationStatusView(state: model.narrationPlaybackState)
                // Offer narration only when the book has NO audio loaded yet.
                if NarrationNudgePolicy.showsNudge(
                    tracksEmpty: model.tracks.isEmpty,
                    isRunning: model.narrationPlaybackState.isRunning)
                {
                    NarrationNudgeView {
                        settings.narrationVoiceID = preferredVoice.id.rawValue
                        model.startNarrationPlayback(voice: preferredVoice)
                    }
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
            }
            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
            .padding(.top, 12)
        }
    }

    private var artworkView: some View {
        Group {
            if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                ZoomableArtwork(
                    image: image,
                    accessibilityLabel: Text("Cover of \(model.currentTitle)")
                ) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
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

            // Hero line: chapter-nav chevrons flank the title marquee. Chevrons
            // reuse skip*Navigation, which uses parsed chapters when available
            // and falls back to folder tracks for MP3-folder books.
            if model.hasChapterNavigation {
                HStack(spacing: 8) {
                    Button {
                        model.skipBackwardNavigation()
                        Haptic.play(.light)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: chevronWidth, height: chevronHitTarget)
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
                            .frame(width: chevronWidth, height: chevronHitTarget)
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
    private let chevronHitTarget: CGFloat = 44

    private var titleText: String {
        model.chapters.count >= 2
            ? (model.currentSubtitle.isEmpty
                ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)")
                : model.currentSubtitle)
            : model.currentTitle
    }

    private var secondaryLineText: String {
        if model.chapters.count >= 2 {
            // Metadata display title, never the raw file slug (audit 2026-07:
            // "SYSTEM-THAT-DOES-THE-REVIEWING" leaked into the eyebrow).
            let bookTitle = model.bookDisplayTitle
            let author = authorText
            return author.isEmpty ? bookTitle : "\(bookTitle) • \(author)"
        } else {
            return authorText.isEmpty ? String(localized: "Audiobook") : authorText
        }
    }

    private var authorText: String {
        // Library metadata first; the parent-folder guess below mislabels
        // category folders ("Books") as the author.
        if let author = model.bookMetadataAuthor {
            return author
        }
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
        let totalBookDuration = model.effectiveBookDuration
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

    private func reloadVisualListeningViewModel() async {
        guard let audiobookID = model.bookIdentityURL?.absoluteString,
            let db = model.databaseService?.writer
        else {
            visualListeningViewModel = nil
            return
        }

        let viewModel = VisualListeningViewModel(audiobookID: audiobookID, db: db)
        viewModel.syncPoint = visualListeningSyncPoint
        await viewModel.reload()
        visualListeningViewModel = viewModel
        updateVisualListeningSnapshot(time: model.currentPlaybackTime)
    }

    private func updateVisualListeningSnapshot(time: TimeInterval) {
        visualListeningViewModel?.update(
            time: time,
            currentTrackSegmentKey: model.currentTrackSegmentKey,
            currentTrackChapterIndices: model.currentTrackChapterIndices
        )
    }

    private func handleTimelineItemsIngested(_ notification: Notification) {
        guard let ingestedID = notification.userInfo?["audiobookID"] as? String,
            ingestedID == model.bookIdentityURL?.absoluteString
        else { return }
        Task { await reloadVisualListeningViewModel() }
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
