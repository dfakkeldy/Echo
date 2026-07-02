// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class StudyDeckGenerationViewModel {
    var cards: [GeneratedStudyDeckCardDraft] = []
    var selectedCardIDs: Set<String> = []
    var isLoading = false
    var isAccepting = false
    var errorMessage: String?
    var acceptedCount = 0
    var acceptedPlanNewCardsPerDay: Int?
    /// `(done, total)` batch progress while a generation run is in flight; `nil` otherwise.
    var progress: (done: Int, total: Int)?

    @ObservationIgnored private let audiobookID: String
    @ObservationIgnored private let bookTitle: String
    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let generator: any StudyDeckGenerating
    @ObservationIgnored private let logger = Logger(category: "StudyDeckGenerationViewModel")
    @ObservationIgnored private var draft: GeneratedStudyDeckDraft?
    @ObservationIgnored private var chapterIndexBySourceBlockID: [String: Int?] = [:]
    /// The in-flight load, owned here so `cancelLoad()` (e.g. the sheet's Cancel button) can cancel it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var selectedCardCount: Int {
        selectedCardIDs.count
    }

    var canAccept: Bool {
        !isLoading && !isAccepting && !cards.isEmpty && !selectedCardIDs.isEmpty
    }

    var canAcceptAll: Bool {
        !isLoading && !isAccepting && !cards.isEmpty
    }

    var chapterGroups: [StudyDeckDraftChapterGroup] {
        let grouped = Dictionary(grouping: cards) { card in
            chapterIndexBySourceBlockID[card.sourceBlockID] ?? nil
        }

        return grouped
            .map { chapterIndex, cards in
                StudyDeckDraftChapterGroup(
                    id: chapterIndex.map { "chapter-\($0)" } ?? "other",
                    chapterIndex: chapterIndex,
                    title: chapterIndex.map { "Chapter \($0 + 1)" } ?? "Other Cards",
                    cards: cards.sorted { $0.sourceBlockID < $1.sourceBlockID }
                )
            }
            .sorted { left, right in
                switch (left.chapterIndex, right.chapterIndex) {
                case let (left?, right?): left < right
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): left.title < right.title
                }
            }
    }

    var acceptedSummaryText: String? {
        guard acceptedCount > 0 else { return nil }
        if let acceptedPlanNewCardsPerDay {
            let unit = acceptedPlanNewCardsPerDay == 1 ? "card" : "cards"
            return
                "\(acceptedCount) cards accepted. Echo will introduce \(acceptedPlanNewCardsPerDay) \(unit) a day for this plan."
        }
        return "\(acceptedCount) cards accepted. New study plans start at 2 AI cards a day."
    }

    var isShowingError: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    init(
        audiobookID: String,
        bookTitle: String,
        db: DatabaseWriter,
        generator: any StudyDeckGenerating = FixtureStudyDeckGenerator()
    ) {
        self.audiobookID = audiobookID
        self.bookTitle = bookTitle
        self.db = db
        self.generator = generator
    }

    /// Runs a cancellable generation. Owns the work in `loadTask` so `cancelLoad()` can stop it,
    /// while keeping the existing `.task { await viewModel.load() }` call site working (we await
    /// the stored task's value).
    func load() async {
        loadTask = Task { await self.runLoad() }
        await loadTask?.value
        loadTask = nil
    }

    /// Cancels an in-flight `load()` (e.g. the sheet's Cancel button).
    func cancelLoad() {
        loadTask?.cancel()
    }

    private func runLoad() async {
        isLoading = true
        defer {
            isLoading = false
            progress = nil
        }

        do {
            errorMessage = nil
            acceptedCount = 0
            acceptedPlanNewCardsPerDay = nil
            progress = nil

            let sources = try StudyDeckSourceBuilder(db: db).sources(
                audiobookID: audiobookID,
                selection: .wholeBook
            )
            chapterIndexBySourceBlockID = Dictionary(
                uniqueKeysWithValues: sources.map { ($0.sourceBlockID, $0.chapterIndex) }
            )
            let generatedDraft = await generator.generate(
                sources: sources,
                settings: StudyDeckGenerationSettings()
            )

            draft = generatedDraft
            cards = generatedDraft.cards
            selectedCardIDs = Set(generatedDraft.cards.map(\.id))
        } catch {
            draft = nil
            cards = []
            selectedCardIDs = []
            chapterIndexBySourceBlockID = [:]
            errorMessage = error.localizedDescription
            logger.error("Failed to generate study deck draft: \(error.localizedDescription)")
        }
    }

    func toggleCard(_ card: GeneratedStudyDeckCardDraft) {
        if selectedCardIDs.contains(card.id) {
            selectedCardIDs.remove(card.id)
        } else {
            selectedCardIDs.insert(card.id)
        }
    }

    func toggleChapter(_ group: StudyDeckDraftChapterGroup) {
        let ids = Set(group.cards.map(\.id))
        if ids.isSubset(of: selectedCardIDs) {
            selectedCardIDs.subtract(ids)
        } else {
            selectedCardIDs.formUnion(ids)
        }
    }

    func selectAllCards() {
        selectedCardIDs = Set(cards.map(\.id))
    }

    @discardableResult
    func acceptAll(now: Date = Date()) -> Bool {
        selectAllCards()
        return accept(now: now)
    }

    @discardableResult
    func accept(now: Date = Date()) -> Bool {
        acceptedCount = 0
        acceptedPlanNewCardsPerDay = nil

        guard let draft else {
            errorMessage = "Generate a study deck draft before accepting cards."
            return false
        }
        guard !selectedCardIDs.isEmpty else {
            errorMessage = "Select at least one card to accept."
            return false
        }

        isAccepting = true
        defer { isAccepting = false }

        do {
            errorMessage = nil
            let acceptedCards = try StudyDeckAcceptanceService(db: db).accept(
                draft,
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                selectedCardIDs: selectedCardIDs,
                now: now
            )
            guard !acceptedCards.isEmpty else {
                errorMessage = "No cards were accepted."
                return false
            }

            acceptedCount = acceptedCards.count
            acceptedPlanNewCardsPerDay = try StudyPlanDAO(db: db)
                .plan(for: audiobookID)?
                .newCardsPerDay
            NotificationCenter.default.post(
                name: .timelineItemsIngested,
                object: nil,
                userInfo: ["audiobookID": audiobookID]
            )
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to accept generated study deck: \(error.localizedDescription)")
            return false
        }
    }
}

struct StudyDeckDraftChapterGroup: Identifiable, Equatable, Sendable {
    let id: String
    let chapterIndex: Int?
    let title: String
    let cards: [GeneratedStudyDeckCardDraft]
}
