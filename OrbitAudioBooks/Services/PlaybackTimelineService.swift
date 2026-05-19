import Foundation
import Observation
import os.log

/// Toggles between real-time (calendar) and playlist-time (media) timeline views.
/// Lives outside any single service so both can reference it without circular imports.
enum TimelineMode {
    case realTime
    case playlistTime
}

/// Dedicated service for the playlist-time (relative media) timeline.
/// Operates strictly on TimeInterval — no Date, calendar, or scheduling concepts.
@Observable
final class PlaybackTimelineService {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "PlaybackTimelineService")
    private let db: DatabaseService?

    // MARK: - Published state

    private(set) var chapterSections: [ChapterSection] = []
    private(set) var timeScale: TimeScale = .minutes

    // MARK: - Dependencies

    private var currentAudiobookID: String?

    init(databaseService: DatabaseService? = nil) {
        self.db = databaseService
    }

    func setTimeScale(_ scale: TimeScale) {
        guard scale != timeScale else { return }
        timeScale = scale
        loadContent()
    }

    func setCurrentAudiobookID(_ id: String?) {
        guard id != currentAudiobookID else { return }
        currentAudiobookID = id
        loadContent()
    }

    // MARK: - Data loading

    private func loadContent() {
        Task {
            do {
                let sections = try loadChapterSections()
                await MainActor.run { self.chapterSections = sections }
            } catch {
                logger.error("Failed to load playlist timeline: \(error.localizedDescription)")
            }
        }
    }

    /// Load only chapter sections that intersect the given time range.
    /// Memory-safe for long audiobooks — only items in [start, end] are fetched.
    func loadWindow(from start: TimeInterval, to end: TimeInterval) throws -> [ChapterSection] {
        guard let db, let audiobookID = currentAudiobookID else { return [] }
        let items = try TimelineDAO(db: db.writer).filtered(
            audiobookID: audiobookID,
            from: start,
            to: end
        )
        let cards = items.map { ContentCard(from: $0) }
        let chapterRecords = try ChapterDAO(db: db.writer).chapters(for: audiobookID)
        let totalDuration = chapterRecords.map(\.endSeconds).max() ?? 0

        let relevantChapters = chapterRecords.filter { rec in
            rec.endSeconds > start && rec.startSeconds < end
        }

        guard !relevantChapters.isEmpty else {
            let fallbackEnd = cards.compactMap(\.mediaTimestamp).max() ?? end
            return [ChapterSection(
                index: 0, title: "Full Book",
                startSeconds: start, endSeconds: max(fallbackEnd, end),
                cards: cards, totalBookDuration: totalDuration
            )]
        }

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
                    totalBookDuration: totalDuration
                ))
            }
        }

        let unmatched = cards.filter { !matchedIDs.contains($0.id) }
        if !unmatched.isEmpty {
            sections.append(ChapterSection(
                index: sections.count,
                title: "Other",
                startSeconds: sections.last?.endSeconds ?? start,
                endSeconds: end,
                cards: unmatched,
                totalBookDuration: totalDuration
            ))
        }

        return sections.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// Builds hierarchical chapter sections by partitioning timeline cards
    /// by chapter time ranges. Pure relative-time — no calendar involvement.
    private func loadChapterSections() throws -> [ChapterSection] {
        guard let db, let audiobookID = currentAudiobookID else { return [] }
        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let cards = items.map { ContentCard(from: $0) }
        let chapterRecords = try ChapterDAO(db: db.writer).chapters(for: audiobookID)
        let totalDuration = chapterRecords.map(\.endSeconds).max() ?? 0

        guard !chapterRecords.isEmpty else {
            let fallbackDuration = cards.compactMap(\.mediaTimestamp).max() ?? 0
            return [ChapterSection(index: 0, title: "Full Book", startSeconds: 0,
                                    endSeconds: fallbackDuration, cards: cards,
                                    totalBookDuration: fallbackDuration)]
        }

        var sections: [ChapterSection] = []
        var matchedIDs = Set<String>()
        for (i, rec) in chapterRecords.enumerated() {
            let chapterCards = cards.filter { card in
                guard let mt = card.mediaTimestamp else { return false }
                return mt >= rec.startSeconds && mt < rec.endSeconds
            }
            matchedIDs.formUnion(chapterCards.map(\.id))
            sections.append(ChapterSection(
                index: i,
                title: rec.title,
                startSeconds: rec.startSeconds,
                endSeconds: rec.endSeconds,
                cards: chapterCards,
                totalBookDuration: totalDuration
            ))
        }

        let unmatched = cards.filter { !matchedIDs.contains($0.id) }
        if !unmatched.isEmpty {
            let unmatchedEnd = unmatched.compactMap(\.mediaTimestamp).max() ?? totalDuration
            sections.append(ChapterSection(
                index: sections.count,
                title: "Other",
                startSeconds: totalDuration,
                endSeconds: max(unmatchedEnd, totalDuration + 1),
                cards: unmatched,
                totalBookDuration: totalDuration
            ))
        }
        return sections
    }
}
