import SwiftUI
import AVFoundation
import WatchConnectivity
import WatchKit
import Observation
import WidgetKit

// MARK: - Content View

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = WatchViewModel()
    @State private var crownAccumulator: Double = 0.0
    @State private var previousCrownOffset: Double = 0.0
    @State private var selectedPage: Int = 0
    @State private var isShowingNewBookmark = false
    @State private var isShowingSleepTimer = false
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
                    onSleepTimer: { isShowingSleepTimer = true }
                )
                    .tag(0)
                if viewModel.page2Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page2Slots,
                        viewModel: viewModel,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true }
                    )
                    .tag(1)
                }

                if viewModel.page3Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page3Slots,
                        viewModel: viewModel,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true }
                    )
                    .tag(2)
                }

                if viewModel.page4Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page4Slots,
                        viewModel: viewModel,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true }
                    )
                    .tag(3)
                }

                if viewModel.page5Slots.contains(where: { $0 != .empty }) {
                    PlayerPage(
                        slots: viewModel.page5Slots,
                        viewModel: viewModel,
                        layout: artworkLayout,
                        onBookmark: { isShowingNewBookmark = true },
                        onSleepTimer: { isShowingSleepTimer = true }
                    )
                    .tag(4)
                }

                if !viewModel.dueCards.isEmpty {
                    WatchReviewView(viewModel: viewModel)
                        .tag(5)
                }
            }
            .tabViewStyle(.page)
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
        .onAppear {
            viewModel.requestCurrentState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.requestCurrentState()
        }
    }

    @State private var accumulatedScrubDelta: Double = 0.0
    @State private var isScrubbingActive: Bool = false
    @State private var scrubIdleTimer: Timer?

    private func handleCrownRotation(offset: Double) {
        let delta = offset - previousCrownOffset
        previousCrownOffset = offset
        guard delta != 0 else { return }

        if viewModel.crownAction == "scrub" {
            scrubIdleTimer?.invalidate()
            
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
            
            // Reset the deadzone if the crown hasn't been moved for 1 second
            scrubIdleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                isScrubbingActive = false
                accumulatedScrubDelta = 0.0
            }
        } else {
            viewModel.sendCommand("volumeDelta", params: ["delta": delta])
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
                Color.black.opacity(0.80)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview {
    ContentView()
}
