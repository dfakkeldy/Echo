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
    @State private var viewModel = WatchViewModel()
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
                    WatchReviewView(viewModel: viewModel)
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
        }
        .focusable(true, interactions: .edit)
        .focused($isFocused)
        .defaultFocus($isFocused, true)
        .digitalCrownRotation($crownAccumulator) { event in
            handleCrownRotation(offset: event.offset)
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

    private func handleCrownRotation(offset: Double) {
        let delta = offset - previousCrownOffset
        previousCrownOffset = offset
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
            viewModel.sendCommand("volumeDelta", params: ["delta": delta])
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
        WatchArtworkLayout(rawValue: viewModel.watchArtworkLayout) ?? .immersive
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
    ContentView()
}
