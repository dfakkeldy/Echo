import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

/// "Twitter-style" scrolling timeline feed supporting both dense (EPUB-aligned)
/// and sparse (audio-only) content through a unified interface.
///
/// ## Layout
/// - Chapter markers render as sticky section headers via `LazyVStack(pinnedViews:)`.
/// - Text segments render as compact "tweet" cells.
/// - Gaps > 60s between items render as `TimeGapCell` spacers.
/// - A floating "↓ Now" button appears when the user scrolls away from the playhead.
///
/// ## Playback Tracking
/// When `isFollowingPlayback` is true, the feed auto-scrolls to keep the current
/// text segment near the center of the screen. Manual scrolling pauses auto-follow
/// for 5 seconds, then it resumes automatically.
struct TimelineFeedView: View {
    @Environment(PlayerModel.self) private var playerModel
    @State private var viewModel = TimelineFeedViewModel()
    @State private var scrollTargetID: String?
    @State private var isUserScrolling = false
    @State private var playbackTime: TimeInterval = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if viewModel.visibleSections.isEmpty {
                emptyState
            } else {
                feedScrollView
            }

            // ── Floating "Go to Now" button ──
            if !viewModel.isFollowingPlayback {
                goToNowButton
            }
        }
        .onAppear { configureIfNeeded() }
        .onChange(of: playerModel.folderURL) { _, newURL in
            viewModel.setAudiobookID(newURL?.absoluteString)
        }
        .onReceive(playbackTimePublisher) { time in
            playbackTime = time
            viewModel.updatePlaybackTime(time)
            if viewModel.isFollowingPlayback {
                updateScrollTarget()
            }
        }
        .onChange(of: isUserScrolling) { _, scrolling in
            if scrolling { viewModel.userDidScroll() }
        }
        .onChange(of: playerModel.speed) { _, newSpeed in
            viewModel.playbackSpeed = Double(newSpeed)
        }
    }

    // MARK: - Feed Scroll View

    private var feedScrollView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.visibleSections) { section in
                    Section {
                        ForEach(section.items) { feedItem in
                            switch feedItem {
                            case .item(let timelineItem):
                                feedItemCell(for: timelineItem)
                            case .timeGap:
                                timeGapRow(feedItem)
                            }
                        }
                    } header: {
                        if let chapter = section.chapter {
                            ChapterHeaderView(
                                title: chapter.title,
                                startTime: section.chapterStartTime,
                                duration: section.duration,
                                isCurrentChapter: chapterInPlaybackRange(chapter, section: section),
                                isPlayed: section.chapterEndTime <= playbackTime
                            )
                            .id(chapter.id)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollPosition(id: $scrollTargetID, anchor: .center)
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { _ in isUserScrolling = true }
                .onEnded { _ in
                    // Brief delay so deceleration finishes before we allow
                    // programmatic scrolls via updateScrollTarget().
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isUserScrolling = false
                    }
                }
        )
        .defaultScrollAnchor(.top)
    }

    // MARK: - Item Cell

    @ViewBuilder
    private func feedItemCell(for item: TimelineItem) -> some View {
        switch item.itemType {
        case .textSegment:
            TimelineTweetCell(
                item: item,
                isCurrentItem: viewModel.currentItemID == item.id,
                isPlayed: item.audioStartTime < playbackTime
            )
            .id(item.id)

        case .bookmark, .ankiCard, .note:
            TimelineContentCard(
                card: ContentCard(from: item),
                isEditing: false
            )
            .padding(.leading, 32)
            .padding(.horizontal)
            .id(item.id)

        case .imageAsset:
            imageAssetCell(for: item)
                .id(item.id)

        default:
            TimelineContentCard(
                card: ContentCard(from: item),
                isEditing: false
            )
            .padding(.horizontal)
            .id(item.id)
        }
    }

    // MARK: - Image Asset Cell

    private func imageAssetCell(for item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let imagePath = item.imagePath, let platformImg = platformImage(from: imagePath) {
                makePlatformImage(platformImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            if !item.title.isEmpty, item.imagePath != nil {
                Text(item.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Time Gap Row

    @ViewBuilder
    private func timeGapRow(_ feedItem: TimelineFeedItem) -> some View {
        if case .timeGap(_, let from, let to, let duration) = feedItem {
            TimeGapCell(
                fromTime: from,
                toTime: to,
                duration: duration,
                isPlayheadWithin: playbackTime >= from && playbackTime < to
            )
            .id(feedItem.id)
        }
    }

    // MARK: - Go to Now Button

    private var goToNowButton: some View {
        Button {
            isUserScrolling = false
            if let targetID = viewModel.goToRightNow(currentPlaybackTime: playbackTime) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollTargetID = targetID
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption)
                Text("Now")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(radius: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
        .accessibilityLabel("Go to current playback position")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        if let errorMessage = viewModel.loadError {
            ContentUnavailableView(
                "Timeline Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else {
            ContentUnavailableView(
                "No Timeline Content",
                systemImage: "text.justify.left",
                description: Text(
                    viewModel.currentAudiobookID == nil
                        ? "Open a folder or audiobook to see its timeline feed."
                        : "This audiobook has no timeline content yet. Bookmarks, notes, and flashcards will appear here."
                )
            )
        }
    }

    // MARK: - Helpers

    private var voiceOverActive: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning
        #else
        false
        #endif
    }

    private func chapterInPlaybackRange(_ chapter: TimelineItem, section: TimelineFeedSection) -> Bool {
        playbackTime >= section.chapterStartTime && playbackTime < section.chapterEndTime
    }

    private func configureIfNeeded() {
        guard let db = playerModel.databaseService,
              let folderURL = playerModel.folderURL else { return }
        viewModel.configure(
            db: db,
            audiobookID: folderURL.absoluteString,
            duration: playerModel.durationSeconds ?? 0
        )
        viewModel.playbackSpeed = Double(playerModel.speed)
    }

    private func updateScrollTarget() {
        // Only update if following playback and VoiceOver is not active.
        guard viewModel.isFollowingPlayback, !voiceOverActive, !isUserScrolling else { return }
        if let currentID = viewModel.currentItemID {
            scrollTargetID = currentID
        }
    }

    /// Polls `playerModel.currentPlaybackTime` every 0.5s.
    private var playbackTimePublisher: AnyPublisher<TimeInterval, Never> {
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .map { [playerModel] _ in playerModel.currentPlaybackTime }
            .eraseToAnyPublisher()
    }

    // MARK: - Platform image loading

    private func platformImage(from path: String) -> PlatformImage? {
        #if os(iOS)
        UIImage(contentsOfFile: path)
        #elseif os(macOS)
        NSImage(contentsOfFile: path)
        #else
        nil
        #endif
    }

    private func makePlatformImage(_ img: PlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: img)
        #elseif os(macOS)
        Image(nsImage: img)
        #endif
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

// MARK: - Chapter Header View

private struct ChapterHeaderView: View {
    let title: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let isCurrentChapter: Bool
    let isPlayed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "forward.end.fill")
                .font(.caption2)
                .foregroundStyle(isCurrentChapter ? .blue : .secondary)

            Text(title)
                .font(.subheadline)
                .fontWeight(isCurrentChapter ? .bold : .semibold)
                .foregroundStyle(isCurrentChapter ? .blue : .primary)

            Spacer(minLength: 8)

            Text(formatHMS(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            if isCurrentChapter {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .opacity(isPlayed && !isCurrentChapter ? 0.6 : 1.0)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    TimelineFeedView()
        .environment(PlayerModel())
}
#endif
