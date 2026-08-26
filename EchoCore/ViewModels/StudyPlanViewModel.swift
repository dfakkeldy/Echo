// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class StudyPlanViewModel {
    var existingPlan: StudyPlan?
    var candidates: [StudyPlanCandidate] = []
    var assignmentRows: [StudyPlanAssignmentRow] = []
    var selectedCandidateIDs: Set<String> = []
    var cadenceUnit: StudyPlanCadenceUnit = .day
    var newChapterLimit: Int = 1
    var newCardsPerDay: Int = 2
    var chapterPacing: StudyPlanChapterPacing = .cardDrain
    var includeImages: Bool = false
    var queueMode: StudyPlanQueueMode = .bookByBook
    var isPaused: Bool = false
    var isLoading: Bool = false
    var errorMessage: String?

    @ObservationIgnored private let audiobookID: String
    @ObservationIgnored private let bookTitle: String
    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let logger = Logger(category: "StudyPlanViewModel")
    @ObservationIgnored private var candidateSelectionOverrides: [String: Bool] = [:]

    var canCreatePlan: Bool {
        existingPlan == nil && !selectedCandidateIDs.isEmpty
    }

    var canEditImageInclusion: Bool {
        true
    }

    var selectedCandidateCount: Int {
        selectedCandidateIDs.count
    }

    var cadenceLabel: String {
        switch cadenceUnit {
        case .day: "day"
        case .week: "week"
        }
    }

    var chapterLimitText: String {
        let unit = newChapterLimit == 1 ? "chapter" : "chapters"
        return "\(newChapterLimit) \(unit) per \(cadenceLabel)"
    }

    var cardLimitText: String {
        let unit = newCardsPerDay == 1 ? "new AI card" : "new AI cards"
        return "\(newCardsPerDay) \(unit) per day"
    }

    init(audiobookID: String, bookTitle: String, db: DatabaseWriter) {
        self.audiobookID = audiobookID
        self.bookTitle = bookTitle
        self.db = db
    }

    func load() {
        performLoading {
            errorMessage = nil
            let dao = StudyPlanDAO(db: db)
            existingPlan = try dao.plan(for: audiobookID)

            if let existingPlan {
                apply(existingPlan)
                assignmentRows = try loadAssignmentRows(planID: existingPlan.id)
                candidates = []
                selectedCandidateIDs = []
            } else {
                assignmentRows = []
                try loadPreviewUsingCurrentImageSetting()
            }
        }
    }

    func refreshPreviewForImageInclusionChange() {
        guard existingPlan == nil else { return }

        performLoading {
            errorMessage = nil
            try loadPreviewUsingCurrentImageSetting()
        }
    }

    func toggleCandidate(_ candidate: StudyPlanCandidate) {
        let isSelected = selectedCandidateIDs.contains(candidate.id)
        let newSelection = !isSelected
        candidateSelectionOverrides[candidate.id] = newSelection

        if newSelection {
            selectedCandidateIDs.insert(candidate.id)
        } else {
            selectedCandidateIDs.remove(candidate.id)
        }
    }

    func assignmentIsEnabled(_ itemID: String) -> Bool {
        assignmentRows.first { $0.id == itemID }?.isEnabled ?? false
    }

    func setAssignmentEnabled(itemID: String, isEnabled: Bool) {
        guard let index = assignmentRows.firstIndex(where: { $0.id == itemID }) else { return }
        assignmentRows[index].isEnabled = isEnabled
    }

    @discardableResult
    func save(now: Date = Date()) -> Bool {
        do {
            errorMessage = nil
            let dao = StudyPlanDAO(db: db)

            if let existingPlan {
                try dao.updateSettings(
                    planID: existingPlan.id,
                    cadenceUnit: cadenceUnit,
                    newChapterLimit: newChapterLimit,
                    newCardsPerDay: newCardsPerDay,
                    chapterPacing: chapterPacing,
                    includeImages: includeImages,
                    queueMode: queueMode,
                    catchUpPolicy: .gentle,
                    now: now
                )
                try dao.setPaused(planID: existingPlan.id, isPaused: isPaused, now: now)
                for row in assignmentRows {
                    try dao.setItemEnabled(itemID: row.id, isEnabled: row.isEnabled, now: now)
                }
                if let savedPlan = try dao.plan(for: audiobookID) {
                    var imageCandidates = [StudyPlanCandidate]()
                    if includeImages {
                        imageCandidates = try StudyPlanGenerator(db: db).preview(
                            audiobookID: audiobookID,
                            bookTitle: bookTitle,
                            includeImages: true
                        ).candidates.filter { $0.kind == .image }
                    }
                    try dao.syncImageItems(
                        for: savedPlan,
                        candidates: imageCandidates,
                        includeImages: includeImages,
                        now: now
                    )
                }
                self.existingPlan = try dao.plan(for: audiobookID)
                if let savedPlan = self.existingPlan {
                    apply(savedPlan)
                    assignmentRows = try loadAssignmentRows(planID: savedPlan.id)
                }
            } else {
                let selectedCandidates = candidatesForCreation()
                guard !selectedCandidates.isEmpty else { return false }

                let result = try dao.createPlan(
                    StudyPlanCreationRequest(
                        audiobookID: audiobookID,
                        bookTitle: bookTitle,
                        cadenceUnit: cadenceUnit,
                        newChapterLimit: newChapterLimit,
                        newCardsPerDay: newCardsPerDay,
                        chapterPacing: chapterPacing,
                        includeImages: includeImages,
                        queueMode: queueMode,
                        catchUpPolicy: .gentle,
                        startDate: now,
                        candidates: selectedCandidates,
                        now: now
                    )
                )
                existingPlan = result.plan
                candidates = []
                assignmentRows = try loadAssignmentRows(planID: result.plan.id)
                selectedCandidateIDs = []
            }

            NotificationCenter.default.post(name: .studyPlanDidChange, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to save study plan: \(error.localizedDescription)")
            return false
        }
    }

    private func performLoading(_ operation: () throws -> Void) {
        isLoading = true
        defer { isLoading = false }

        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load study plan: \(error.localizedDescription)")
        }
    }

    private func apply(_ plan: StudyPlan) {
        cadenceUnit = StudyPlanCadenceUnit(rawValue: plan.cadenceUnit) ?? .day
        newChapterLimit = max(1, plan.newChapterLimit)
        newCardsPerDay = min(max(1, plan.newCardsPerDay), 100)
        chapterPacing = StudyPlanChapterPacing(rawValue: plan.chapterPacing) ?? .cardDrain
        includeImages = plan.includeImages
        queueMode = StudyPlanQueueMode(rawValue: plan.queueModeDefault) ?? .bookByBook
        isPaused = plan.isPaused
    }

    private func loadPreviewUsingCurrentImageSetting() throws {
        let preview = try StudyPlanGenerator(db: db).preview(
            audiobookID: audiobookID,
            bookTitle: bookTitle,
            includeImages: includeImages
        )

        candidates = preview.candidates
        selectedCandidateIDs = Set(
            preview.candidates.compactMap { candidate in
                let isSelected = candidateSelectionOverrides[candidate.id] ?? candidate.defaultIncluded
                return isSelected ? candidate.id : nil
            }
        )
    }

    private func loadAssignmentRows(planID: String) throws -> [StudyPlanAssignmentRow] {
        let items = try StudyPlanDAO(db: db).items(for: planID)
            .filter { $0.kind == StudyPlanItemKind.chapter.rawValue }
        let cardIDs = items.compactMap(\.flashcardID)
        guard !cardIDs.isEmpty else { return [] }

        let cardsByID = try db.read { db in
            let cards = try Flashcard
                .filter(cardIDs.contains(Column("id")))
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        }

        return items.compactMap { item in
            guard let flashcardID = item.flashcardID,
                let card = cardsByID[flashcardID]
            else {
                return nil
            }

            return StudyPlanAssignmentRow(
                id: item.id,
                flashcardID: flashcardID,
                title: card.frontText,
                chapterIndex: item.chapterIndex,
                isEnabled: item.isEnabled && card.isEnabled
            )
        }
    }

    private func candidatesForCreation() -> [StudyPlanCandidate] {
        candidates
            .filter { selectedCandidateIDs.contains($0.id) }
            .map { candidate in
                StudyPlanCandidate(
                    id: candidate.id,
                    kind: candidate.kind,
                    sourceBlockID: candidate.sourceBlockID,
                    chapterIndex: candidate.chapterIndex,
                    ordinal: candidate.ordinal,
                    title: candidate.title,
                    defaultIncluded: true,
                    imagePath: candidate.imagePath,
                    mediaTimestamp: candidate.mediaTimestamp,
                    endTimestamp: candidate.endTimestamp,
                    playlistPosition: candidate.playlistPosition
                )
            }
    }
}

struct StudyPlanAssignmentRow: Identifiable, Equatable, Sendable {
    let id: String
    let flashcardID: String
    let title: String
    let chapterIndex: Int?
    var isEnabled: Bool

    var detail: String {
        guard let chapterIndex else { return "Re-listen card" }
        return "Chapter \(chapterIndex + 1) re-listen card"
    }
}
