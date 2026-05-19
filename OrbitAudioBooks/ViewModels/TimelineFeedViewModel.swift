import Foundation
import Observation
import UIKit

/// Push-driven feed view model. Audio engine pushes position →
/// feed scrolls reactively with a rolling window of TimelineItems.
@Observable
final class TimelineFeedViewModel {
    // MARK: - Published state

    private(set) var items: [TimelineItem] = []
    private(set) var currentPosition: TimeInterval = 0
    private(set) var granularity: GranularityLevel = .sentence
    private(set) var isFollowingPlayback = true
    private(set) var isLoading = false

    /// Externally controlled: set true when VoiceOver is running.
    var isVoiceOverRunning: Bool = false

    /// Externally controlled: playback speed from the audio engine.
    var playbackSpeed: Double = 1.0 {
        didSet { updateGranularity() }
    }

    // MARK: - Dependencies

    private let dao: TimelineDAO
    private let audiobookID: String
    private let windowSize = 100

    // MARK: - Tripwire state

    private var tripwireTask: Task<Void, Never>?
    private let tripwireDelay: TimeInterval = 5.0

    // MARK: - Callbacks

    var onScrollToPosition: ((TimeInterval) -> Void)?
    var onItemsChanged: (() -> Void)?

    init(dao: TimelineDAO, audiobookID: String) {
        self.dao = dao
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
        scheduleTripwireReset()
    }

    /// "Go to Now" — re-enable follow mode and scroll to current position.
    func goToNow() {
        isFollowingPlayback = true
        tripwireTask?.cancel()
        if !isVoiceOverRunning {
            onScrollToPosition?(currentPosition)
        }
    }

    /// Load the initial window around the given position.
    func loadInitialWindow(around position: TimeInterval) async {
        isLoading = true
        defer { isLoading = false }

        do {
            items = try dao.feedWindow(
                audiobookID: audiobookID,
                around: position,
                granularity: granularity,
                limit: windowSize
            )
            onItemsChanged?()
        } catch {
            items = []
        }
    }

    /// Load the next page (after the last item's position).
    func loadNextPage() async {
        guard let lastItem = items.last else { return }
        let after = lastItem.effectivePosition
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try dao.feedPage(
                audiobookID: audiobookID,
                after: after,
                granularity: granularity,
                limit: 50
            )
            guard !page.isEmpty else { return }
            items.append(contentsOf: page)
            onItemsChanged?()
        } catch {}
    }

    /// Load the previous page (before the first item's position).
    func loadPreviousPage() async {
        guard let firstItem = items.first else { return }
        let before = firstItem.effectivePosition
        isLoading = true
        defer { isLoading = false }

        do {
            // Fetch items before the first one by querying around but shifting back
            let page = try dao.feedPage(
                audiobookID: audiobookID,
                after: max(0, before - 3600),
                granularity: granularity,
                limit: 50
            )
            let filtered = page.filter { $0.effectivePosition < before }
            guard !filtered.isEmpty else { return }
            items.insert(contentsOf: filtered, at: 0)
            onItemsChanged?()
        } catch {}
    }

    /// Reload at a different granularity (e.g., when speed changes).
    func reloadGranularity() async {
        guard !items.isEmpty else { return }
        let mid = currentPosition
        isLoading = true
        defer { isLoading = false }

        do {
            items = try dao.feedWindow(
                audiobookID: audiobookID,
                around: mid,
                granularity: granularity,
                limit: windowSize
            )
            onItemsChanged?()
        } catch {}
    }

    // MARK: - Private

    private func updateGranularity() {
        let newGranularity: GranularityLevel = playbackSpeed > 1.5 ? .chapter : .sentence
        guard newGranularity != granularity else { return }
        granularity = newGranularity
        Task { await reloadGranularity() }
    }

    private func scheduleTripwireReset() {
        tripwireTask?.cancel()
        tripwireTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(tripwireDelay * 1_000_000_000))
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
