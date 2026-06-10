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
@MainActor @Observable
final class PlaybackTimelineService {
    private let logger = Logger(category: "PlaybackTimelineService")
    private let db: DatabaseService?

    // MARK: - Published state

    private(set) var chapterSections: [ChapterSection] = []
    private(set) var timeScale: TimelineScope = .chapter

    // MARK: - Dependencies

    private var currentAudiobookID: String?

    init(databaseService: DatabaseService? = nil) {
        self.db = databaseService
    }

    func setTimeScale(_ scale: TimelineScope) {
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
        do {
            let sections = try loadChapterSections()
            chapterSections = sections
        } catch {
            logger.error("Failed to load playlist timeline: \(error.localizedDescription)")
        }
    }

    /// Builds hierarchical chapter sections by partitioning timeline cards
    /// by chapter time ranges. Pure relative-time — no calendar involvement.
    /// DAOs manage their own GRDB read transactions internally.
    private func loadChapterSections() throws -> [ChapterSection] {
        guard let db, let audiobookID = currentAudiobookID else { return [] }
        let dbWriter = db.writer
        let timelineDAO = TimelineDAO(db: dbWriter)
        let chapterDAO = ChapterDAO(db: dbWriter)
        let items = try timelineDAO.items(for: audiobookID)
        let chapterRecords = try chapterDAO.chapters(for: audiobookID)
        let cards = items.map { ContentCard(from: $0) }
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
