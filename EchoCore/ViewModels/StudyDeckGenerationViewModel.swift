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
    /// `(done, total)` batch progress while a generation run is in flight; `nil` otherwise.
    var progress: (done: Int, total: Int)?

    @ObservationIgnored private let audiobookID: String
    @ObservationIgnored private let bookTitle: String
    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let generator: any StudyDeckGenerating
    @ObservationIgnored private let logger = Logger(category: "StudyDeckGenerationViewModel")
    @ObservationIgnored private var draft: GeneratedStudyDeckDraft?
    /// The in-flight load, owned here so `cancelLoad()` (e.g. the sheet's Cancel button) can cancel it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var selectedCardCount: Int {
        selectedCardIDs.count
    }

    var canAccept: Bool {
        !isLoading && !isAccepting && !cards.isEmpty && !selectedCardIDs.isEmpty
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
            progress = nil

            let sources = try StudyDeckSourceBuilder(db: db).sources(
                audiobookID: audiobookID,
                selection: .wholeBook
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

    @discardableResult
    func accept(now: Date = Date()) -> Bool {
        acceptedCount = 0

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
