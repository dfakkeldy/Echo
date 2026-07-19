// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Full-screen overlay hosting the configured floating glass buttons for the
    /// experimental player. Locked mode only in Task 2 — buttons dispatch their
    /// actions; Task 3 adds edit mode. The layer itself never intercepts touches
    /// outside button frames (no background, hit-testing falls through).
    struct ExperimentalControlLayer: View {
        @Environment(PlayerModel.self) private var model
        @Environment(SettingsManager.self) private var settings

        // Overflow closures, injected from RootTabView (same set as PlayerMoreMenu).
        let onShowChapters: () -> Void
        let onShowBookmarks: () -> Void
        let onShowPlaybackOptions: () -> Void
        let onStats: () -> Void
        let onFidget: () -> Void
        let onSettings: () -> Void
        let onHelp: () -> Void
        let onAddDocument: (() -> Void)?
        let onExport: (() -> Void)?
        let onStudyNotesExport: (() -> Void)?

        @State private var containerSize: CGSize = .zero

        private var layout: ExperimentalPlayerLayout {
            ExperimentalPlayerLayout.decode(settings.experimentalPlayerLayoutData)
        }

        var body: some View {
            ZStack {
                ForEach(layout.buttons) { button in
                    controlButton(for: button.action)
                        .position(
                            PlayerZoneResolver.center(
                                for: button.zone, offset: button.offset,
                                in: containerSize, diameter: diameter(for: button.action)))
                }

                overflowMenu
                    .position(
                        PlayerZoneResolver.center(
                            for: .upperTrailing, offset: .zero,
                            in: containerSize, diameter: 44))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                containerSize = newSize
            }
        }

        private func diameter(for action: WatchAction) -> CGFloat {
            action == .playPause ? 68 : 52
        }

        /// Fixed, non-configurable overflow — everything not promoted to a button.
        private var overflowMenu: some View {
            PlayerMoreMenu(
                onShowChapters: onShowChapters,
                onShowBookmarks: onShowBookmarks,
                onStats: onStats,
                onFidget: onFidget,
                onSettings: onSettings,
                onHelp: onHelp,
                onAddDocument: onAddDocument,
                onExport: onExport,
                onStudyNotesExport: onStudyNotesExport
            )
            .frame(width: 44, height: 44)
            .modifier(GlassCircleBackground())
        }

        @ViewBuilder
        private func controlButton(for action: WatchAction) -> some View {
            switch action {
            case .playPause:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.togglePlayPause()
                    Haptic.play(.light)
                }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(model.resolvedThemeTint ?? .accentColor)
                }
                .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

            case .skipBackward:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipBackward30()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(
                        systemName: WatchAction.skipBackward.dynamicIconName(
                            forDuration: settings.seekBackwardDuration)
                    )
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Skip back \(settings.seekBackwardDuration) seconds"))

            case .skipForward:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipForward30()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(
                        systemName: WatchAction.skipForward.dynamicIconName(
                            forDuration: settings.seekForwardDuration)
                    )
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Skip forward \(settings.seekForwardDuration) seconds"))

            case .previousTrack:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipBackwardNavigation()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(
                    model.chapters.count >= 2 ? Text("Previous chapter") : Text("Previous track"))

            case .nextTrack:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipForwardNavigation()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(
                    model.chapters.count >= 2 ? Text("Next chapter") : Text("Next track"))

            case .previousSection:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.previousSectionOrRestart()
                    Haptic.play(.light)
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Previous section"))

            case .nextSection:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.nextSection()
                    Haptic.play(.light)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Next section"))

            case .loopMode:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.cycleLoopMode()
                    Haptic.play(.medium)
                }) {
                    Image(systemName: "infinity")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(model.loopMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                }
                .accessibilityLabel(Text("Loop mode"))

            case .speed:
                GlassControlButton(diameter: diameter(for: action), action: {
                    onShowPlaybackOptions()
                    Haptic.play(.light)
                }) {
                    Text(
                        model.speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
                    )
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Playback options"))

            case .sleepTimer:
                Menu {
                    Button("15 Minutes", systemImage: "15.circle") {
                        model.setSleepTimer(.minutes(15))
                    }
                    Button("30 Minutes", systemImage: "30.circle") {
                        model.setSleepTimer(.minutes(30))
                    }
                    Button("45 Minutes", systemImage: "45.circle") {
                        model.setSleepTimer(.minutes(45))
                    }
                    Button("1 Hour", systemImage: "1.circle") {
                        model.setSleepTimer(.minutes(60))
                    }
                    Divider()
                    Button("End of Chapter", systemImage: "book.closed") {
                        model.setSleepTimer(.endOfChapter)
                    }
                    if model.sleepTimerMode.isActive {
                        Divider()
                        Button("Off", systemImage: "xmark.circle", role: .destructive) {
                            model.cancelSleepTimer()
                        }
                    }
                } label: {
                    Image(
                        systemName: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz"
                    )
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(
                        width: diameter(for: action), height: diameter(for: action))
                    .contentShape(.circle)
                }
                .modifier(GlassCircleBackground())
                .accessibilityLabel(Text("Sleep Timer"))

            case .bookmark:
                GlassControlButton(diameter: diameter(for: action), action: {
                    if let draft = model.bookmarkDraftAtCurrentTime() {
                        model.activeBookmarkDraft = draft
                        Haptic.play(.medium)
                    }
                }) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Add bookmark"))
                .disabled(model.tracks.isEmpty)

            case .markPassage:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.markPassageAtCurrentTime()
                    Haptic.play(.light)
                }) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Mark passage for later"))
                .disabled(model.tracks.isEmpty)

            case .pomodoro, .empty:
                EmptyView()
            }
        }
    }
#endif
