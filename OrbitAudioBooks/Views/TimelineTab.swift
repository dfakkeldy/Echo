import SwiftUI
import UIKit

struct TimelineTab: View {
    @Environment(PlayerModel.self) private var model
    @State private var timeScale: TimeScale = .minutes
    @State private var dueCount: Int = 0
    @State private var feedViewModel: TimelineFeedViewModel?
    @State private var isFollowingPlayback = true
    @State private var feedItems: [TimelineItem] = []
    @State private var currentPosition: TimeInterval = 0

    var onReviewTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            TimelineHeaderView(
                timeScale: $timeScale,
                onRecenterNow: {
                    feedViewModel?.goToNow()
                }
            )

            Divider()

            DashboardShelf(onReviewTap: onReviewTap)

            if dueCount > 0 {
                dueReviewBanner
            }

            // The unified dual-path feed
            if let viewModel = feedViewModel {
                ZStack {
                    TimelineFeedCollectionView(
                        items: $feedItems,
                        currentPosition: $currentPosition,
                        isFollowingPlayback: isFollowingPlayback,
                        onUserScrolled: {
                            viewModel.userDidScroll()
                        }
                    )

                    // "Go to Now" floating button (visible when not following)
                    if !isFollowingPlayback {
                        VStack {
                            Spacer()
                            Button {
                                viewModel.goToNow()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.to.line")
                                    Text("Go to Now")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .shadow(radius: 4)
                            }
                            .padding(.bottom, 12)
                        }
                    }
                }
            } else {
                ProgressView()
                    .padding(.top, 40)
            }
        }
        .onAppear {
            refreshDueCount()
            setupFeed()
        }
        .onChange(of: model.currentPlaybackTime) { _, newPosition in
            currentPosition = newPosition
            feedViewModel?.updatePosition(newPosition)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            feedViewModel?.isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        }
    }

    // MARK: - Private

    private var dueReviewBanner: some View {
        Button {
            onReviewTap?()
        } label: {
            HStack {
                Label("\(dueCount) cards due for review", systemImage: "rectangle.stack.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func setupFeed() {
        guard let db = model.databaseService,
              let audiobookID = model.folderURL?.absoluteString
        else { return }

        let dao = TimelineDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(dao: dao, audiobookID: audiobookID)
        viewModel.isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        viewModel.playbackSpeed = Double(model.speed)

        // Wire scroll callback
        viewModel.onScrollToPosition = { position in
            // Position-based scroll handled by the collection view's coordinator
        }

        // Wire item change callback
        viewModel.onItemsChanged = {
            feedItems = viewModel.items
            isFollowingPlayback = viewModel.isFollowingPlayback
        }

        self.feedViewModel = viewModel
        feedItems = viewModel.items

        Task {
            await viewModel.loadInitialWindow(around: model.currentPlaybackTime)
        }
    }

    private func refreshDueCount() {
        guard let db = model.databaseService else { return }
        dueCount = (try? FlashcardDAO(db: db.writer).allDueCards().count) ?? 0
    }
}
