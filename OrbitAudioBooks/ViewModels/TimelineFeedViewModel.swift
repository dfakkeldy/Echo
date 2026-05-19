import Foundation
import Observation
import os.log

/// ViewModel for the Twitter-Feed audiobook timeline.
///
/// Owns a rolling time-window of `TimelineItem`s loaded via `TimelineDAO`
/// so memory stays constant regardless of audiobook length. Groups items
/// by chapter for sticky section headers and tracks whether the feed
/// should auto-follow the playback position.
@Observable
final class TimelineFeedViewModel {

    // MARK: - Follow state

    enum FollowState: Equatable {
        /// Feed auto-scrolls to keep the playhead visible.
        case following
        /// User scrolled away — feed stays put.
        case browsing
    }

    // MARK: - Published state

    private(set) var chapterSections: [ChapterSection] = []
    private(set) var followState: FollowState = .following
    private(set) var isLoadingEarlier = false
    private(set) var isLoadingLater = false
    private(set) var hasEarlierContent = false
    private(set) var hasLaterContent = false

    /// The chapter index that currently contains the playback position.
    private(set) var currentChapterIndex: Int?

    // MARK: - Playback position (written by the View)

    var currentPlaybackTime: TimeInterval = 0
    var isPlaying: Bool = false

    /// ID of the item closest to `currentPlaybackTime` — used for ScrollViewReader.
    var currentItemID: String? {
        allCardsInWindow
            .min(by: { abs(($0.mediaTimestamp ?? 0) - currentPlaybackTime) < abs(($1.mediaTimestamp ?? 0) - currentPlaybackTime) })?
            .id
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "TimelineFeedVM")
    private let db: DatabaseService?
    private let windowSize: TimeInterval
    private var audiobookID: String?
    private var totalDuration: TimeInterval = 0
    private var lastUserScrollTime: Date = .distantPast
    private let autoFollowTimeout: TimeInterval = 30

    /// All cards across all sections in the current window, in display order.
    private var allCardsInWindow: [ContentCard] {
        chapterSections.flatMap(\.cards)
    }

    // MARK: - Init

    init(databaseService: DatabaseService?, windowSize: TimeInterval = 1800) {
        self.db = databaseService
        self.windowSize = windowSize
    }

    // MARK: - Configuration

    func configure(audiobookID: String?, totalDuration: TimeInterval) {
        guard audiobookID != self.audiobookID || totalDuration != self.totalDuration else { return }
        self.audiobookID = audiobookID
        self.totalDuration = totalDuration
        chapterSections = []
        hasEarlierContent = false
        hasLaterContent = false
        if audiobookID != nil {
            loadWindow(around: currentPlaybackTime > 0 ? currentPlaybackTime : 0)
        }
    }

    // MARK: - Window loading

    /// Load (or reload) the rolling window centred on `time`.
    func loadWindow(around time: TimeInterval) {
        let half = windowSize / 2
        let start = max(0, time - half)
        let end = min(totalDuration > 0 ? totalDuration : (time + half), time + half)
        loadRange(from: start, to: end, direction: nil)
    }

    /// Extend the window backward (infinite scroll upward).
    func loadEarlier() {
        guard !isLoadingEarlier, let first = chapterSections.first else { return }
        let newEnd = first.startSeconds
        let newStart = max(0, newEnd - windowSize)
        if newStart >= newEnd { hasEarlierContent = false; return }
        isLoadingEarlier = true
        Task {
            defer { isLoadingEarlier = false }
            await loadAndMerge(from: newStart, to: newEnd, direction: .earlier)
        }
    }

    /// Extend the window forward (infinite scroll downward).
    func loadLater() {
        guard !isLoadingLater, let last = chapterSections.last else { return }
        let newStart = last.endSeconds
        let limit = totalDuration > 0 ? totalDuration : (newStart + windowSize)
        let newEnd = min(limit, newStart + windowSize)
        if newStart >= newEnd { hasLaterContent = false; return }
        isLoadingLater = true
        Task {
            defer { isLoadingLater = false }
            await loadAndMerge(from: newStart, to: newEnd, direction: .later)
        }
    }

    // MARK: - Follow state

    /// Call when the user manually scrolls the feed.
    func userDidScroll() {
        lastUserScrollTime = Date()
        if followState == .following {
            followState = .browsing
        }
        scheduleAutoFollowCheck()
    }

    /// Jump the feed to the current playback position and resume following.
    func jumpToNow() {
        followState = .following
        loadWindow(around: currentPlaybackTime)
    }

    // MARK: - Private helpers

    private enum LoadDirection { case earlier, later }

    private func loadRange(from start: TimeInterval, to end: TimeInterval, direction: LoadDirection?) {
        Task {
            do {
                let sections = try buildSections(from: start, to: end)
                await MainActor.run {
                    self.chapterSections = sections
                    self.hasEarlierContent = start > 0
                    let limit = self.totalDuration > 0 ? self.totalDuration : .infinity
                    self.hasLaterContent = end < limit
                    self.refreshCurrentChapterIndex()
                }
            } catch {
                logger.error("Failed to load window [\(start)-\(end)]: \(error.localizedDescription)")
            }
        }
    }

    private func loadAndMerge(from start: TimeInterval, to end: TimeInterval, direction: LoadDirection) async {
        do {
            let newSections = try buildSections(from: start, to: end)
            await MainActor.run {
                let merged: [ChapterSection]
                switch direction {
                case .earlier:
                    merged = Self.mergeSections(newSections, self.chapterSections)
                case .later:
                    merged = Self.mergeSections(self.chapterSections, newSections)
                }
                self.chapterSections = merged
                self.hasEarlierContent = (merged.first?.startSeconds ?? 0) > 0
                let limit = self.totalDuration > 0 ? self.totalDuration : .infinity
                self.hasLaterContent = (merged.last?.endSeconds ?? 0) < limit
                self.refreshCurrentChapterIndex()
            }
        } catch {
            logger.error("Failed to load range [\(start)-\(end)]: \(error.localizedDescription)")
        }
    }

    private func buildSections(from start: TimeInterval, to end: TimeInterval) throws -> [ChapterSection] {
        guard let db, let audiobookID else { return [] }
        let items = try TimelineDAO(db: db.writer).filtered(
            audiobookID: audiobookID,
            from: start,
            to: end
        )
        let cards = items.map { ContentCard(from: $0) }
        let chapterRecords = try ChapterDAO(db: db.writer).chapters(for: audiobookID)
        let totalDur = totalDuration > 0 ? totalDuration : (chapterRecords.map(\.endSeconds).max() ?? 0)

        // Only include chapters that intersect the loaded range.
        let relevantChapters = chapterRecords.filter { rec in
            rec.endSeconds > start && rec.startSeconds < end
        }

        guard !relevantChapters.isEmpty else {
            let fallbackEnd = cards.compactMap(\.mediaTimestamp).max() ?? end
            return [ChapterSection(
                index: 0, title: "Full Book",
                startSeconds: start, endSeconds: max(fallbackEnd, end),
                cards: cards, totalBookDuration: totalDur
            )]
        }

        // Assign each card to its chapter.
        var sections: [ChapterSection] = []
        var matchedIDs = Set<String>()
        for rec in relevantChapters {
            let chapterCards = cards.filter { card in
                guard let mt = card.mediaTimestamp else { return false }
                return mt >= rec.startSeconds && mt < rec.endSeconds
            }
            matchedIDs.formUnion(chapterCards.map(\.id))
            if !chapterCards.isEmpty || rec.endSeconds > start {
                sections.append(ChapterSection(
                    index: rec.sortOrder,
                    title: rec.title,
                    startSeconds: max(rec.startSeconds, start),
                    endSeconds: min(rec.endSeconds, end),
                    cards: chapterCards,
                    totalBookDuration: totalDur
                ))
            }
        }

        // Unmatched items get a catch-all section.
        let unmatched = cards.filter { !matchedIDs.contains($0.id) }
        if !unmatched.isEmpty {
            sections.append(ChapterSection(
                index: sections.count,
                title: "Other",
                startSeconds: sections.last?.endSeconds ?? start,
                endSeconds: end,
                cards: unmatched,
                totalBookDuration: totalDur
            ))
        }

        return sections.sorted { $0.startSeconds < $1.startSeconds }
    }

    private func refreshCurrentChapterIndex() {
        guard !chapterSections.isEmpty else { currentChapterIndex = nil; return }
        var best = chapterSections[0].index
        for section in chapterSections {
            if currentPlaybackTime >= section.startSeconds && currentPlaybackTime < section.endSeconds {
                best = section.index
                break
            }
        }
        currentChapterIndex = best
    }

    /// Merge two sorted, non-overlapping section arrays, deduplicating by index.
    private static func mergeSections(_ a: [ChapterSection], _ b: [ChapterSection]) -> [ChapterSection] {
        var seen: Set<Int> = []
        var result: [ChapterSection] = []
        for section in a + b {
            if seen.insert(section.index).inserted {
                result.append(section)
            }
        }
        result.sort { $0.startSeconds < $1.startSeconds }
        return result
    }

    // MARK: - Auto-follow timer

    private func scheduleAutoFollowCheck() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoFollowTimeout))
            let elapsed = Date().timeIntervalSince(lastUserScrollTime)
            if elapsed >= autoFollowTimeout && followState == .browsing {
                // Only snap back if the playhead is still inside the current window.
                if let first = chapterSections.first, let last = chapterSections.last,
                   currentPlaybackTime >= first.startSeconds - 10,
                   currentPlaybackTime <= last.endSeconds + 10 {
                    followState = .following
                }
            }
        }
    }
}
