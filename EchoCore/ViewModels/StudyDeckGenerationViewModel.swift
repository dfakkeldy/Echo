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

    @ObservationIgnored private let audiobookID: String
    @ObservationIgnored private let bookTitle: String
    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let logger = Logger(category: "StudyDeckGenerationViewModel")
    @ObservationIgnored private var draft: GeneratedStudyDeckDraft?

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

    init(audiobookID: String, bookTitle: String, db: DatabaseWriter) {
        self.audiobookID = audiobookID
        self.bookTitle = bookTitle
        self.db = db
    }

    func load() {
        isLoading = true
        defer { isLoading = false }

        do {
            errorMessage = nil
            acceptedCount = 0

            let sources = try StudyDeckSourceBuilder(db: db).sources(
                audiobookID: audiobookID,
                selection: .wholeBook
            )
            let generatedDraft = FixtureStudyDeckGenerator().generate(sources: sources)

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
