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
                PlayerPage(
                    slots: viewModel.page2Slots,
                    viewModel: viewModel,
                    layout: artworkLayout,
                    onBookmark: { isShowingNewBookmark = true },
                    onSleepTimer: { isShowingSleepTimer = true }
                )
                    .tag(1)
                WordCloudPage(viewModel: viewModel)
                    .tag(2)
                if !viewModel.dueCards.isEmpty {
                    WatchReviewView(viewModel: viewModel)
                        .tag(3)
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

    private func handleCrownRotation(offset: Double) {
        let delta = offset - previousCrownOffset
        previousCrownOffset = offset
        guard delta != 0 else { return }

        if viewModel.crownAction == "scrub" {
            viewModel.sendCommand("scrubDelta", params: ["delta": delta])
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
                GeometryReader { proxy in
                    let availableSide = min(proxy.size.width, proxy.size.height)
                    let blurredSide = availableSide * 0.94
                    let artworkSide = availableSide * 0.72

                    ZStack {
                        Color.black

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: blurredSide, height: blurredSide)
                            .blur(radius: 10)
                            .opacity(0.30)
                            .accessibilityHidden(true)

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: artworkSide, height: artworkSide)
                            .opacity(0.58)
                            .accessibilityLabel(Text(viewModel.title))
                            .accessibilityAddTraits(.isImage)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .overlay(Color.black.opacity(0.30))
                .overlay(artworkScrim)
                .ignoresSafeArea()
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
