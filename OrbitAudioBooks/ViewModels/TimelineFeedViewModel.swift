import Foundation
import Observation
import UIKit

/// Push-driven feed view model. Audio engine pushes position →
/// feed scrolls reactively with a rolling window of TimelineDisplayItems.
///
/// Data source dynamically switches based on `scope`:
/// - `.book`: queries `AudiobookDAO.all()` → `.audiobookCard` items
/// - `.chapter`: queries `TimelineDAO.feedWindow(granularity: .chapter)` → `.timelineItem` items
/// - `.transcription`: queries `TimelineDAO.feedWindow(granularity: .sentence)` → `.timelineItem` items
@Observable
final class TimelineFeedViewModel {
    // MARK: - Published state

    // MARK: - Feed mode

    enum FeedMode: Equatable {
        case followingPlayback
        case browsing
        case searchingToAnchor
        case editingAlignment(selectedBlockID: String)
    }

    private(set) var items: [TimelineDisplayItem] = []
    private(set) var currentPosition: TimeInterval = 0
    private(set) var isFollowingPlayback = true
    private(set) var feedMode: FeedMode = .followingPlayback
    private(set) var isLoading = false
    private(set) var lastError: Error?
    private(set) var searchQuery: String = ""
    private(set) var searchResults: [EPubBlockRecord] = []
    var isSearching: Bool { feedMode == .searchingToAnchor }

    /// The active structural zoom level. Setting this triggers a data reload.
    var scope: TimelineScope = .chapter {
        didSet {
            guard oldValue != scope else { return }
            granularity = scope.defaultGranularity
            Task { await reloadScope() }
        }
    }

    /// Database-level granularity, derived from scope (and auto-adjusted for speed).
    private(set) var granularity: GranularityLevel = .sentence

    /// Externally controlled: set true when VoiceOver is running.
    var isVoiceOverRunning: Bool = false

    /// Externally controlled: playback speed from the audio engine.
    var playbackSpeed: Double = 1.0 {
        didSet { updateGranularity() }
    }

    // MARK: - Dependencies

    private let timelineDAO: TimelineDAO
    private let audiobookDAO: AudiobookDAO
    private let audiobookID: String?
    private let windowSize = 100

    // MARK: - Tripwire state

    private var tripwireTask: Task<Void, Never>?
    private let tripwireDelay: TimeInterval = 5.0

    // MARK: - Callbacks

    var onScrollToPosition: ((TimeInterval) -> Void)?
    var onItemsChanged: (() -> Void)?

    init(timelineDAO: TimelineDAO, audiobookDAO: AudiobookDAO, audiobookID: String?) {
        self.timelineDAO = timelineDAO
        self.audiobookDAO = audiobookDAO
        self.audiobookID = audiobookID
    }

    // MARK: - Public API

    /// Called by the audio engine on every tick (0.25s interval).
    func updatePosition(_ position: TimeInterval) {
        currentPosition = position
        guard isFollowingPlayback, !isVoiceOverRunning else { return }
        onScrollToPosition?(position)
    }

    /// Called when the user manually scrolls the feed.
    func userDidScroll() {
        guard isFollowingPlayback else { return }
        isFollowingPlayback = false
        feedMode = .browsing
        scheduleTripwireReset()
    }

    /// "Go to Now" — re-enable follow mode and scroll to current position.
    func goToNow() {
        isFollowingPlayback = true
        feedMode = .followingPlayback
        tripwireTask?.cancel()
        if !isVoiceOverRunning {
            onScrollToPosition?(currentPosition)
        }
    }

    // MARK: - Search-to-Anchor

    /// Enters search mode for anchoring.
    func beginSearchToAnchor() {
        feedMode = .searchingToAnchor
        searchQuery = ""
        searchResults = []
    }

    /// Cancels search and returns to prior mode.
    func cancelSearch() {
        feedMode = isFollowingPlayback ? .followingPlayback : .browsing
        searchQuery = ""
        searchResults = []
    }

    /// Performs a search across EPUB block text and populates results.
    func searchBlocks(query: String) {
        searchQuery = query
        guard !query.isEmpty, let audiobookID else {
            searchResults = []
            return
        }

        // Search from the DB — hidden blocks excepted unless "show hidden" is on.
        let blockDAO = EPubBlockDAO(db: timelineDAO.db)
        searchResults = (try? blockDAO.searchBlocks(for: audiobookID, query: query)) ?? []
    }

    /// Anchors a search result at the current playback time and exits search mode.
    func anchorSearchResult(blockID: String, at time: TimeInterval) async {
        guard let audiobookID else { return }
        let db = timelineDAO.db
        let service = AlignmentService(db: db, audiobookID: audiobookID)
        do {
            try service.anchorSearchResult(blockID: blockID, time: time)
            await loadTimelineWindow(around: time)
        } catch {
            lastError = error
        }
        cancelSearch()
    }

    // MARK: - Context Menu Actions

    /// Moves a block's anchor to the current playback time.
    func moveBlockToNow(blockID: String) {
        guard let audiobookID else { return }
        let db = timelineDAO.db
        let service = AlignmentService(db: db, audiobookID: audiobookID)
        do {
            try service.moveBlockToCurrentTime(blockID: blockID, time: currentPosition)
            Task { await loadTimelineWindow(around: currentPosition) }
        } catch {
            lastError = error
        }
    }

    /// Hides a block from the feed.
    func hideBlock(blockID: String, reason: String?) {
        guard let audiobookID else { return }
        let db = timelineDAO.db
        let service = AlignmentService(db: db, audiobookID: audiobookID)
        do {
            try service.hideBlock(blockID: blockID, reason: reason)
            Task { await loadTimelineWindow(around: currentPosition) }
        } catch {
            lastError = error
        }
    }

    /// Unhides a previously hidden block.
    func unhideBlock(blockID: String) {
        guard let audiobookID else { return }
        let db = timelineDAO.db
        let service = AlignmentService(db: db, audiobookID: audiobookID)
        do {
            try service.unhideBlock(blockID: blockID)
            Task { await loadTimelineWindow(around: currentPosition) }
        } catch {
            lastError = error
        }
    }

    /// Load the initial window around the given position.
    func loadInitialWindow(around position: TimeInterval) async {
        isLoading = true
        defer { isLoading = false }

        switch scope {
        case .book:
            await loadBookScope()
        case .chapter, .transcription:
            await loadTimelineWindow(around: position)
        }
    }

    /// Load the next page (after the last item's effective position).
    func loadNextPage() async {
        guard !items.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        switch scope {
        case .book:
            // Book scope loads all books at once; no pagination needed.
            return
        case .chapter, .transcription:
            let lastPosition = items.lazy.compactMap { item -> TimeInterval? in
                if case .timelineItem(let ti) = item { return ti.effectivePosition }
                return nil
            }.last ?? 0

            do {
                let page = try timelineDAO.feedPage(
                    audiobookID: audiobookID ?? "",
                    after: lastPosition,
                    granularity: granularity,
                    limit: 50
                )
                guard !page.isEmpty else { return }
                let newItems = prepareDisplayItems(from: page)
                items.append(contentsOf: newItems)
                onItemsChanged?()
            } catch {
                lastError = error
            }
        }
    }

    /// Load the previous page (before the first item's position).
    func loadPreviousPage() async {
        guard !items.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        switch scope {
        case .book:
            return
        case .chapter, .transcription:
            let firstPosition = items.lazy.compactMap { item -> TimeInterval? in
                if case .timelineItem(let ti) = item { return ti.effectivePosition }
                return nil
            }.first ?? 0

            do {
                let page = try timelineDAO.feedPage(
                    audiobookID: audiobookID ?? "",
                    after: max(0, firstPosition - 3600),
                    granularity: granularity,
                    limit: 50
                )
                let filtered = page.filter { $0.effectivePosition < firstPosition }
                guard !filtered.isEmpty else { return }
                let newItems = prepareDisplayItems(from: filtered)
                items.insert(contentsOf: newItems, at: 0)
                onItemsChanged?()
            } catch {
                lastError = error
            }
        }
    }

    /// Reload at a different granularity (e.g., when speed changes).
    func reloadGranularity() async {
        await loadTimelineWindow(around: currentPosition)
    }

    /// Full reload triggered by scope change.
    func reloadScope() async {
        isLoading = true
        defer { isLoading = false }

        switch scope {
        case .book:
            await loadBookScope()
        case .chapter, .transcription:
            await loadTimelineWindow(around: currentPosition)
        }
    }

    // MARK: - Private: Data Loading

    private func loadBookScope() async {
        do {
            let audiobooks = try audiobookDAO.all()
            let displayItems: [TimelineDisplayItem] = audiobooks.map { record in
                .audiobookCard(AudiobookCardInfo(
                    id: record.id,
                    title: record.title,
                    author: record.author,
                    duration: record.duration,
                    fileCount: record.fileCount,
                    isCurrentlyPlaying: record.id == (audiobookID ?? ""),
                    addedAt: record.addedAt
                ))
            }
            items = displayItems
            onItemsChanged?()
        } catch {
            lastError = error
            // Keep existing items rather than replacing with empty feed
        }
    }

    private func loadTimelineWindow(around position: TimeInterval) async {
        guard let audiobookID else {
            items = []
            onItemsChanged?()
            return
        }

        do {
            let rawItems = try timelineDAO.feedWindow(
                audiobookID: audiobookID,
                around: position,
                granularity: granularity,
                limit: windowSize
            )
            items = prepareDisplayItems(from: rawItems)
            onItemsChanged?()
        } catch {
            lastError = error
            // Keep existing items rather than replacing with empty feed
        }
    }

    // MARK: - Display Item Assembly

    /// Converts raw timeline items into display items, inserting NowLine and
    /// scrubber gaps at the appropriate positions.
    private func prepareDisplayItems(from rawItems: [TimelineItem]) -> [TimelineDisplayItem] {
        guard !rawItems.isEmpty else { return [] }

        var result: [TimelineDisplayItem] = []
        let gapThreshold: TimeInterval = 60.0
        var nowLineInserted = false

        for (index, item) in rawItems.enumerated() {
            // Insert NowLine at the current position boundary
            if !nowLineInserted && item.effectivePosition > currentPosition {
                result.append(.nowLine)
                nowLineInserted = true
            }

            // Insert scrubber gap for large time gaps
            if index > 0 {
                let prev = rawItems[index - 1]
                let gap = item.effectivePosition - prev.effectivePosition
                if gap > gapThreshold {
                    let gapID = "gap-\(prev.id)-to-\(item.id)"
                    result.append(.scrubberGap(duration: gap, id: gapID))
                }
            }

            result.append(.timelineItem(item))
        }

        // If NowLine wasn't inserted (all items before current position), append at end
        if !nowLineInserted {
            result.append(.nowLine)
        }

        return result
    }

    // MARK: - Private Helpers

    private func updateGranularity() {
        let newGranularity: GranularityLevel = playbackSpeed > 1.5 ? .chapter : scope.defaultGranularity
        guard newGranularity != granularity else { return }
        granularity = newGranularity
        Task { await reloadGranularity() }
    }

    private func scheduleTripwireReset() {
        tripwireTask?.cancel()
        let delay = tripwireDelay
        tripwireTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.isFollowingPlayback = true
                if !self.isVoiceOverRunning {
                    self.onScrollToPosition?(self.currentPosition)
                }
            }
        }
    }
}

private extension TimelineScope {
    /// Maps user-facing scope to the default database granularity for queries.
    var defaultGranularity: GranularityLevel {
        switch self {
        case .book:      return .chapter
        case .chapter:   return .chapter
        case .transcription: return .sentence
        }
    }
}
