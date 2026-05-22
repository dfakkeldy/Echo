import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TimelineTab: View {
    @Environment(PlayerModel.self) private var model
    @State private var timelineScope: TimelineScope = .chapter
    @State private var dueCount: Int = 0
    @State private var feedViewModel: TimelineFeedViewModel?
    @State private var isFollowingPlayback = true
    @State private var feedItems: [TimelineDisplayItem] = []
    @State private var currentPosition: TimeInterval = 0
    @State private var scrollTargetPosition: TimeInterval?

    var onReviewTap: (() -> Void)?
    /// Callback to present the bookmark editor sheet in the parent view.
    var onEditBookmark: ((UUID) -> Void)?
    /// Callback to create a new bookmark draft.
    var onCreateBookmark: ((BookmarkDraft) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if model.hasEPUB || model.hasTranscript {
                TimelineHeaderView(
                    scope: $timelineScope,
                    onRecenterNow: {
                        feedViewModel?.goToNow()
                    }
                )

                Divider()

                DashboardShelf(onReviewTap: onReviewTap)

                SpeedSuggestionBanner()

                if dueCount > 0 {
                    dueReviewBanner
                }

                if let viewModel = feedViewModel {
                    ZStack {
                        TimelineFeedCollectionView(
                            items: $feedItems,
                            currentPosition: $currentPosition,
                            scrollTargetPosition: $scrollTargetPosition,
                            isFollowingPlayback: isFollowingPlayback,
                            onUserScrolled: {
                                viewModel.userDidScroll()
                            },
                            onItemTapped: { displayItem in
                                handleItemTap(displayItem)
                            },
                            onContextMenuAction: { displayItem in
                                handleContextMenu(displayItem)
                            },
                            onDeleteBookmark: { timelineItem in
                                handleDeleteBookmark(timelineItem)
                            },
                            onEPUBBlockAction: { item, action in
                                handleEPUBBlockAction(item, action)
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
            } else {
                PlaylistView(isEmbedded: true)
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
        .onChange(of: timelineScope) { _, newScope in
            feedViewModel?.scope = newScope
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            feedViewModel?.isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) { notification in
            guard let ingestedID = notification.userInfo?["audiobookID"] as? String,
                  let audiobookID = model.folderURL?.absoluteString,
                  ingestedID == audiobookID,
                  let viewModel = feedViewModel
            else { return }
            Task {
                await viewModel.loadInitialWindow(around: model.currentPlaybackTime)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
            guard let viewModel = feedViewModel else { return }
            Task {
                await viewModel.loadInitialWindow(around: model.currentPlaybackTime)
            }
        }
        .overlay(alignment: .top) {
            if feedViewModel?.feedMode == .searchingToAnchor {
                searchOverlay
            }
        }
    }

    // MARK: - Search Overlay

    private var searchOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search EPUB text...", text: Binding(
                    get: { feedViewModel?.searchQuery ?? "" },
                    set: { feedViewModel?.search($0) }
                ))
                .textFieldStyle(.plain)

                Button("Cancel") {
                    feedViewModel?.cancelSearch()
                }
                .font(.caption)
            }
            .padding(12)
            .background(.ultraThinMaterial)

            if let results = feedViewModel?.searchResults, !results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { result in
                            Button {
                                feedViewModel?.anchorSearchResult(
                                    result, at: model.currentPlaybackTime
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.text)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    Text("Seq: \(result.sequenceIndex)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Item Tap Handling

    private func handleItemTap(_ displayItem: TimelineDisplayItem) {
        switch displayItem {
        case .audiobookCard(let info):
            // Switch to the selected audiobook
            guard info.id != model.folderURL?.absoluteString else { return }
            let url = URL(fileURLWithPath: info.id)
            let gotAccess = url.startAccessingSecurityScopedResource()
            if gotAccess {
                model.loadFolder(url)
                // Switch to chapter scope to show the book's content
                timelineScope = .chapter
            } else {
                // Fallback: try to restore security-scoped bookmark
                model.loadFolder(url)
                timelineScope = .chapter
            }

        case .timelineItem(let item):
            switch item.itemType {
            case .textSegment, .chapterMarker, .bookmark:
                guard item.isTimestamped else { return }
                model.seek(toSeconds: item.audioStartTime)
            case .imageAsset:
                if let path = item.imagePath, let url = URL(string: "file://\(path)") {
                    UIApplication.shared.open(url)
                }
            case .ankiCard:
                onReviewTap?()
            }

        case .nowLine, .scrubberGap:
            break
        }
    }

    /// Long-press context menu → edit or delete the item.
    private func handleContextMenu(_ displayItem: TimelineDisplayItem) {
        switch displayItem {
        case .timelineItem(let item):
            if item.itemType == .bookmark,
               let sourceRowid = item.sourceRowid,
               let uuid = UUID(uuidString: sourceRowid) {
                onEditBookmark?(uuid)
            } else {
                model.seek(toSeconds: item.audioStartTime)
            }
        case .audiobookCard:
            // Context menu on book card: no extra action needed beyond tap-to-play
            break
        case .nowLine, .scrubberGap:
            break
        }
    }

    /// Handle EPUB block context menu actions.
    private func handleEPUBBlockAction(_ item: TimelineItem, _ action: TimelineFeedCollectionView.EPUBBlockAction) {
        guard let viewModel = feedViewModel else { return }
        switch action {
        case .playFromHere:
            model.seek(toSeconds: item.audioStartTime)
        case .moveToNow:
            guard let blockID = item.epubBlockID else { return }
            viewModel.moveBlockToNow(blockID: blockID, time: model.currentPlaybackTime)
        case .searchSimilar:
            guard let text = item.textPayload else { return }
            viewModel.beginSearch()
            viewModel.search(text)
        case .hide:
            guard let blockID = item.epubBlockID else { return }
            viewModel.hideBlock(blockID: blockID, reason: "user_hidden")
        case .unhide:
            guard let blockID = item.epubBlockID else { return }
            viewModel.unhideBlock(blockID: blockID)
        }
    }

    /// Delete a bookmark from the timeline context menu.
    private func handleDeleteBookmark(_ item: TimelineItem) {
        guard let sourceRowid = item.sourceRowid,
              let uuid = UUID(uuidString: sourceRowid) else { return }
        model.deleteBookmark(id: uuid)
        // Feed will refresh via .bookmarksDidChange notification
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
        guard let db = model.databaseService else { return }

        let audiobookID = model.folderURL?.absoluteString
        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: audiobookID
        )
        viewModel.scope = timelineScope
        viewModel.isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        viewModel.playbackSpeed = Double(model.speed)

        // Wire scroll callback: view model pushes position → state triggers updateUIView.
        viewModel.onScrollToPosition = { [weak viewModel] position in
            guard viewModel?.isFollowingPlayback == true else { return }
            scrollTargetPosition = position
        }

        // Wire follow playback: view model callback → state → collection view scroll.
        viewModel.onScrollToPosition = { position in
            scrollTargetPosition = position
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

// MARK: - Bookmark Change Notification

extension Notification.Name {
    /// Posted when the bookmark store persists changes (add, update, delete).
    /// The Timeline feed observes this to refresh inline bookmark items.
    static let bookmarksDidChange = Notification.Name("BookmarksDidChange")
}
