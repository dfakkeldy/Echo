// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Observation
import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

// MARK: - Content View

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    // Owned by Echo_WatchApp (not this view) so the view model — and the
    // WCSession it activates — also exists during background launches, where
    // no window content is ever built.
    let viewModel: WatchViewModel
    @State private var crownAccumulator: Double = 0.0
    @State private var previousCrownOffset: Double = 0.0
    @State private var selectedPage: Int = 0
    @State private var isShowingNewBookmark = false
    @State private var isShowingSleepTimer = false
    @State private var isArtworkFullscreen = false
    @State private var isShowingPomodoroPicker = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            artworkBackground

            TabView(selection: $selectedPage) {
                PlayerPage(
                    slots: viewModel.page1Slots,
                    viewModel: viewModel,
                    isPrimaryActionEnabled: selectedPage == 0,
                    layout: artworkLayout,
                    onBookmark: { isShowingNewBookmark = true },
                    onSleepTimer: { isShowingSleepTimer = true },
                    onArtworkTap: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isArtworkFullscreen = true
                        }
                    },
                    onPomodoroLongPress: {
                        isShowingPomodoroPicker = true
                    }
                )
                .tag(0)
                if viewModel.page2Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page2Slots,
                        viewModel: viewModel,
                        isPrimaryActionEnabled: selectedPage == 1,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true },
                        onArtworkTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isArtworkFullscreen = true
                            }
                        },
                        onPomodoroLongPress: {
                            isShowingPomodoroPicker = true
                        }
                    )
                    .tag(1)
                }

                if viewModel.page3Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page3Slots,
                        viewModel: viewModel,
                        isPrimaryActionEnabled: selectedPage == 2,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true },
                        onArtworkTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isArtworkFullscreen = true
                            }
                        },
                        onPomodoroLongPress: {
                            isShowingPomodoroPicker = true
                        }
                    )
                    .tag(2)
                }

                if viewModel.page4Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page4Slots,
                        viewModel: viewModel,
                        isPrimaryActionEnabled: selectedPage == 3,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true },
                        onArtworkTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isArtworkFullscreen = true
                            }
                        },
                        onPomodoroLongPress: {
                            isShowingPomodoroPicker = true
                        }
                    )
                    .tag(3)
                }

                if viewModel.page5Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page5Slots,
                        viewModel: viewModel,
                        isPrimaryActionEnabled: selectedPage == 4,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true },
                        onArtworkTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isArtworkFullscreen = true
                            }
                        },
                        onPomodoroLongPress: {
                            isShowingPomodoroPicker = true
                        }
                    )
                    .tag(4)
                }

                if !viewModel.dueCards.isEmpty {
                    WatchReviewView(
                        viewModel: viewModel,
                        isPrimaryActionEnabled: selectedPage == 5
                    )
                    .tag(5)
                }
            }
            .tabViewStyle(.page)

            // Date overlay at the top left of the screen (opposite side of system time)
            if viewModel.watchDateEnabled {
                VStack {
                    HStack {
                        Text(dateString)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.leading, 12)
                            .padding(.top, 16)
                        Spacer()
                    }
                    Spacer()
                }
                .ignoresSafeArea(.all, edges: .top)
                .allowsHitTesting(false)
            }

            // Fullscreen Artwork Viewer Overlay
            if isArtworkFullscreen, let image = viewModel.thumbnailImage {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isArtworkFullscreen = false
                    }
                } label: {
                    ZStack {
                        Color.black.ignoresSafeArea()

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(.top, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
            }

            // Transient crown-volume HUD; sits above the fullscreen artwork so
            // volume feedback stays visible there too. Gate matches
            // handleCrownRotation: anything that isn't scrub drives volume.
            if isVolumeIndicatorVisible && viewModel.crownAction != "scrub" {
                VolumeIndicatorView(
                    fraction: viewModel.volumeFraction,
                    tint: viewModel.artworkAccentColor ?? .accentColor
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .zIndex(20)
                .allowsHitTesting(false)
            }
        }
        .focusable(true, interactions: .edit)
        .focused($isFocused)
        .defaultFocus($isFocused, true)
        .digitalCrownRotation(
            $crownAccumulator,
            from: -1_000,
            through: 1_000,
            by: 0.01,
            sensitivity: .medium,
            isContinuous: true,
            // System detents would click on every hair-tick regardless of
            // whether anything changed; haptics are played manually instead,
            // only when a real control threshold is crossed (volume step /
            // scrub engage), and they respect the app's haptics setting.
            isHapticFeedbackEnabled: false
        )
        .onChange(of: crownAccumulator) { _, newValue in
            handleCrownRotation(offset: newValue)
        }
        .sheet(isPresented: $isShowingNewBookmark) {
            NewBookmarkView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingSleepTimer) {
            SleepTimerView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingPomodoroPicker) {
            PomodoroTimerPickerView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.refreshAfterWake()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.refreshAfterWake()
        }
        .onChange(of: isLuminanceReduced) { _, newValue in
            guard !newValue else { return }
            viewModel.refreshAfterWake()
        }
    }

    @State private var accumulatedScrubDelta: Double = 0.0
    @State private var isScrubbingActive: Bool = false
    @State private var scrubIdleTask: Task<Void, Never>?
    @State private var isVolumeIndicatorVisible = false
    @State private var volumeIndicatorHideTask: Task<Void, Never>?
    @State private var pendingVolumeDelta: Double = 0.0
    @State private var volumeSendTask: Task<Void, Never>?

    private func handleCrownRotation(offset: Double) {
        var delta = offset - previousCrownOffset
        previousCrownOffset = offset
        // `isContinuous` wraps the accumulator between -1000 and +1000; correct
        // the delta so a wrap doesn't register as one giant rotation.
        if delta > 1_000 {
            delta -= 2_000
        } else if delta < -1_000 {
            delta += 2_000
        }
        guard delta != 0 else { return }

        if viewModel.crownAction == "scrub" {
            scrubIdleTask?.cancel()

            if isScrubbingActive {
                viewModel.sendCommand("scrubDelta", params: ["delta": delta])
            } else {
                accumulatedScrubDelta += delta
                // Require ~10% of a full rotation to break the deadzone and begin scrubbing
                if abs(accumulatedScrubDelta) > 0.10 {
                    isScrubbingActive = true
                    // The one haptic that matters in scrub mode: the moment the
                    // deadzone breaks and the crown actually takes control.
                    viewModel.playScrubEngageHaptic()
                    viewModel.sendCommand("scrubDelta", params: ["delta": accumulatedScrubDelta])
                    accumulatedScrubDelta = 0.0
                }
            }

            // Reset the deadzone if the crown hasn't been moved for 1 second.
            // A MainActor Task (not a Timer) so the state mutations stay on the
            // main actor under Swift 6 strict concurrency.
            scrubIdleTask = Task {
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled else { return }
                isScrubbingActive = false
                accumulatedScrubDelta = 0.0
            }
        } else {
            // Optimistic local gain mirror drives the indicator; a haptic fires
            // only when the change crosses a discrete volume step.
            if viewModel.applyLocalVolumeDelta(delta) {
                viewModel.playCrownStepHaptic()
            }
            showVolumeIndicator()
            queueVolumeDelta(delta)
        }
    }

    /// Shows the transient volume HUD and (re)arms its auto-hide.
    private func showVolumeIndicator() {
        withAnimation(.easeOut(duration: 0.15)) {
            isVolumeIndicatorVisible = true
        }
        volumeIndicatorHideTask?.cancel()
        volumeIndicatorHideTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                isVolumeIndicatorVisible = false
            }
        }
    }

    /// Coalesces per-tick crown deltas into one WCSession message every ~80 ms
    /// instead of flooding the channel with a sendMessage per hair-tick.
    private func queueVolumeDelta(_ delta: Double) {
        pendingVolumeDelta += delta
        guard volumeSendTask == nil else { return }
        volumeSendTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            volumeSendTask = nil
            let accumulated = pendingVolumeDelta
            pendingVolumeDelta = 0.0
            guard !Task.isCancelled, accumulated != 0 else { return }
            viewModel.sendCommand("volumeDelta", params: ["delta": accumulated])
        }
    }

    private var dateString: String {
        let date = Date.now
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))

        let useShortFormat: Bool
        switch viewModel.watchDateFormat {
        case "short":
            useShortFormat = true
        case "long":
            useShortFormat = false
        default:  // "auto"
            useShortFormat = WKInterfaceDevice.current().screenBounds.width < 175
        }

        if useShortFormat {
            // "Mon 06/08"
            let month = date.formatted(.dateTime.month(.twoDigits))
            let day = date.formatted(.dateTime.day(.twoDigits))
            return "\(weekday) \(month)/\(day)"
        } else {
            // "Mon Jun 8"
            let month = date.formatted(.dateTime.month(.abbreviated))
            let day = date.formatted(.dateTime.day())
            return "\(weekday) \(month) \(day)"
        }
    }

    private var artworkLayout: WatchArtworkLayout {
        WatchArtworkLayout(rawValue: viewModel.watchArtworkLayout) ?? .classic
    }

    private var backgroundStyle: WatchBackgroundStyle {
        WatchBackgroundStyle(rawValue: viewModel.watchBackgroundStyle) ?? .artwork
    }

    @ViewBuilder
    private var artworkBackground: some View {
        if artworkLayout == .classic && backgroundStyle == .black {
            Color.black.ignoresSafeArea()
        } else if let image = viewModel.thumbnailImage {
            switch artworkLayout {
            case .immersive:
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.30))
                    .overlay(artworkScrim)
                    .accessibilityLabel(Text(viewModel.title))
                    .accessibilityAddTraits(.isImage)
            case .classic:
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.6))
                    .accessibilityHidden(true)
            }
        } else if let ramp = viewModel.coverRampGradient {
            // No artwork on the watch — the image is a bounded transfer that
            // often has not arrived, or never will. The cover's ramp still
            // crossed as two hex strings, so the book keeps its room instead of
            // falling back to an anonymous black rectangle.
            ramp.ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var artworkScrim: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(0.70),
                Color.black.opacity(0.16),
                Color.black.opacity(0.80),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview {
    ContentView(viewModel: WatchViewModel())
}
