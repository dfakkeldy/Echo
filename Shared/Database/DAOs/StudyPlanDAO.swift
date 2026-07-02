// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlanCreationRequest: Sendable {
    let audiobookID: String
    let bookTitle: String
    let cadenceUnit: StudyPlanCadenceUnit
    let newChapterLimit: Int
    let includeImages: Bool
    let queueMode: StudyPlanQueueMode
    let catchUpPolicy: StudyPlanCatchUpPolicy
    let startDate: Date
    let candidates: [StudyPlanCandidate]
    let now: Date
}

struct StudyPlanCreationResult: Sendable {
    let plan: StudyPlan
    let createdCards: [Flashcard]
    let createdItems: [StudyPlanItem]
}

/// The chapter assignment a finished chapter checkpoints against.
struct StudyCheckpointAssignment: Sendable {
    let plan: StudyPlan
    let item: StudyPlanItem
    let card: Flashcard
}

struct StudyPlanDAO {
    let db: DatabaseWriter

    func plan(for audiobookID: String) throws -> StudyPlan? {
        try db.read { db in
            try latestPlan(for: audiobookID, db: db)
        }
    }

    func activePlans() throws -> [StudyPlan] {
        try db.read { db in
            try StudyPlan
                .filter(Column("is_paused") == false)
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)
        }
    }

    func plansForQueue() throws -> [StudyPlan] {
        try db.read { db in
            try StudyPlan
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)
        }
    }

    func items(for planID: String) throws -> [StudyPlanItem] {
        try db.read { db in
            try StudyPlanItem
                .filter(Column("plan_id") == planID)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
    }

    func createPlan(_ request: StudyPlanCreationRequest) throws -> StudyPlanCreationResult {
        let included = request.candidates.filter(\.defaultIncluded)
        let boundedLimit = max(1, request.newChapterLimit)
        let nowString = request.now.ISO8601Format()
        let startString = request.startDate.ISO8601Format()

        return try db.write { db in
            if let existingPlan = try latestPlan(for: request.audiobookID, db: db) {
                return StudyPlanCreationResult(
                    plan: existingPlan,
                    createdCards: [],
                    createdItems: []
                )
            }

            let deckID = try findOrCreateDeck(named: request.bookTitle, nowString: nowString, db: db)
            var plan = StudyPlan(
                id: UUID().uuidString,
                audiobookID: request.audiobookID,
                deckID: deckID,
                cadenceUnit: request.cadenceUnit.rawValue,
                newChapterLimit: boundedLimit,
                includeImages: request.includeImages,
                queueModeDefault: request.queueMode.rawValue,
                catchUpPolicy: request.catchUpPolicy.rawValue,
                startDate: startString,
                isPaused: false,
                createdAt: nowString,
                modifiedAt: nowString
            )
            try plan.insert(db)

            var createdCards: [Flashcard] = []
            var createdItems: [StudyPlanItem] = []

            for candidate in included {
                if try existingItemCount(sourceBlockID: candidate.sourceBlockID, kind: candidate.kind, db: db) > 0 {
                    continue
                }

                let card = makeFlashcard(
                    request: request,
                    candidate: candidate,
                    deckID: deckID,
                    nowString: nowString
                )
                try FlashcardDAO.insert(card, in: db)

                var item = StudyPlanItem(
                    id: UUID().uuidString,
                    planID: plan.id,
                    flashcardID: card.id,
                    kind: candidate.kind.rawValue,
                    chapterIndex: candidate.chapterIndex,
                    sourceBlockID: candidate.sourceBlockID,
                    ordinal: candidate.ordinal,
                    introducedAt: nil,
                    isEnabled: true,
                    createdAt: nowString,
                    modifiedAt: nowString
                )
                try item.insert(db)

                createdCards.append(card)
                createdItems.append(item)
            }

            return StudyPlanCreationResult(plan: plan, createdCards: createdCards, createdItems: createdItems)
        }
    }

    func markIntroduced(itemIDs: [String], now: Date = Date()) throws {
        guard !itemIDs.isEmpty else { return }

        let nowString = now.ISO8601Format()
        try db.write { db in
            _ = try StudyPlanItem
                .filter(itemIDs.contains(Column("id")))
                .filter(Column("introduced_at") == nil)
                .updateAll(db, [
                    Column("introduced_at").set(to: nowString),
                    Column("modified_at").set(to: nowString),
                ])
        }
    }

    func updateSettings(
        planID: String,
        cadenceUnit: StudyPlanCadenceUnit,
        newChapterLimit: Int,
        includeImages: Bool,
        queueMode: StudyPlanQueueMode,
        catchUpPolicy: StudyPlanCatchUpPolicy,
        now: Date = Date()
    ) throws {
        try db.write { db in
            _ = try StudyPlan
                .filter(Column("id") == planID)
                .updateAll(db, [
                    Column("cadence_unit").set(to: cadenceUnit.rawValue),
                    Column("new_chapter_limit").set(to: max(1, newChapterLimit)),
                    Column("include_images").set(to: includeImages),
                    Column("queue_mode_default").set(to: queueMode.rawValue),
                    Column("catch_up_policy").set(to: catchUpPolicy.rawValue),
                    Column("modified_at").set(to: now.ISO8601Format()),
                ])
        }
    }

    func setPaused(planID: String, isPaused: Bool, now: Date = Date()) throws {
        try db.write { db in
            _ = try StudyPlan
                .filter(Column("id") == planID)
                .updateAll(db, [
                    Column("is_paused").set(to: isPaused),
                    Column("modified_at").set(to: now.ISO8601Format()),
                ])
        }
    }

    func setItemEnabled(itemID: String, isEnabled: Bool, now: Date = Date()) throws {
        try db.write { db in
            _ = try StudyPlanItem
                .filter(Column("id") == itemID)
                .updateAll(db, [
                    Column("is_enabled").set(to: isEnabled),
                    Column("modified_at").set(to: now.ISO8601Format()),
                ])
        }
    }

    /// The assignment a naturally finished chapter should checkpoint against,
    /// or nil when the chapter is not covered by an active, introduced,
    /// enabled, due or in-progress study-plan item.
    func checkpointAssignment(
        audiobookID: String,
        chapterIndex: Int,
        now: Date = Date()
    ) throws -> StudyCheckpointAssignment? {
        let nowString = now.ISO8601Format()
        return try db.read { db in
            let plans = try StudyPlan
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_paused") == false)
                .filter(Column("start_date") <= nowString)
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)

            var candidates: [StudyCheckpointAssignment] = []
            for plan in plans {
                let items = try StudyPlanItem
                    .filter(Column("plan_id") == plan.id)
                    .filter(Column("kind") == StudyPlanItemKind.chapter.rawValue)
                    .filter(Column("chapter_index") == chapterIndex)
                    .filter(Column("is_enabled") == true)
                    .filter(Column("introduced_at") != nil)
                    .fetchAll(db)

                for item in items {
                    guard let flashcardID = item.flashcardID,
                        let card = try Flashcard.fetchOne(db, key: flashcardID),
                        card.isEnabled
                    else { continue }

                    let isInProgress = card.repetitions == 0 && card.lastReviewedAt == nil
                    let isDue = card.nextReviewDate.map { $0 <= nowString } ?? false
                    if isInProgress || isDue {
                        candidates.append(
                            StudyCheckpointAssignment(plan: plan, item: item, card: card))
                    }
                }
            }

            return candidates.min { left, right in
                (left.card.nextReviewDate ?? "") < (right.card.nextReviewDate ?? "")
            }
        }
    }

    @discardableResult
    func syncImageItems(
        for plan: StudyPlan,
        candidates: [StudyPlanCandidate],
        includeImages: Bool,
        now: Date = Date()
    ) throws -> [StudyPlanItem] {
        let nowString = now.ISO8601Format()

        return try db.write { db in
            let imageItems = try StudyPlanItem
                .filter(Column("plan_id") == plan.id)
                .filter(Column("kind") == StudyPlanItemKind.image.rawValue)
                .fetchAll(db)
            let flashcardIDs = imageItems.compactMap(\.flashcardID)

            _ = try StudyPlanItem
                .filter(Column("plan_id") == plan.id)
                .filter(Column("kind") == StudyPlanItemKind.image.rawValue)
                .updateAll(db, [
                    Column("is_enabled").set(to: includeImages),
                    Column("modified_at").set(to: nowString),
                ])

            if !flashcardIDs.isEmpty {
                _ = try Flashcard
                    .filter(flashcardIDs.contains(Column("id")))
                    .updateAll(db, [
                        Column("is_enabled").set(to: includeImages),
                        Column("modified_at").set(to: nowString),
                    ])
            }

            guard includeImages else {
                return []
            }

            let existingSources = Set(imageItems.compactMap(\.sourceBlockID))
            let missingCandidates = candidates
                .filter { $0.kind == .image && $0.defaultIncluded }
                .filter { !existingSources.contains($0.sourceBlockID) }
            var createdItems: [StudyPlanItem] = []

            for candidate in missingCandidates {
                if try existingItemCount(sourceBlockID: candidate.sourceBlockID, kind: candidate.kind, db: db) > 0 {
                    continue
                }

                let card = makeFlashcard(
                    audiobookID: plan.audiobookID,
                    candidate: candidate,
                    deckID: plan.deckID,
                    nowString: nowString
                )
                try FlashcardDAO.insert(card, in: db)

                var item = StudyPlanItem(
                    id: UUID().uuidString,
                    planID: plan.id,
                    flashcardID: card.id,
                    kind: candidate.kind.rawValue,
                    chapterIndex: candidate.chapterIndex,
                    sourceBlockID: candidate.sourceBlockID,
                    ordinal: candidate.ordinal,
                    introducedAt: nil,
                    isEnabled: true,
                    createdAt: nowString,
                    modifiedAt: nowString
                )
                try item.insert(db)
                createdItems.append(item)
            }

            return createdItems
        }
    }

    private func latestPlan(for audiobookID: String, db: Database) throws -> StudyPlan? {
        try StudyPlan
            .filter(Column("audiobook_id") == audiobookID)
            .order(Column("created_at").desc)
            .fetchOne(db)
    }

    private func findOrCreateDeck(named name: String, nowString: String, db: Database) throws -> String {
        if let existing: String = try String.fetchOne(
            db,
            sql: "SELECT id FROM deck WHERE name = ? ORDER BY created_at LIMIT 1",
            arguments: [name]
        ) {
            return existing
        }

        let id = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'auto', ?, ?)
                """,
            arguments: [id, name, nowString, nowString]
        )
        return id
    }

    private func existingItemCount(sourceBlockID: String, kind: StudyPlanItemKind, db: Database) throws -> Int {
        try StudyPlanItem
            .filter(Column("source_block_id") == sourceBlockID)
            .filter(Column("kind") == kind.rawValue)
            .fetchCount(db)
    }

    private func makeFlashcard(
        request: StudyPlanCreationRequest,
        candidate: StudyPlanCandidate,
        deckID: String,
        nowString: String
    ) -> Flashcard {
        makeFlashcard(
            audiobookID: request.audiobookID,
            candidate: candidate,
            deckID: deckID,
            nowString: nowString
        )
    }

    private func makeFlashcard(
        audiobookID: String,
        candidate: StudyPlanCandidate,
        deckID: String?,
        nowString: String
    ) -> Flashcard {
        let isImage = candidate.kind == .image
        let cardType = isImage
            ? StudyFlashcardType.imageAssignment
            : StudyFlashcardType.listeningAssignment
        let backText = isImage
            ? "Review what this image adds to the chapter."
            : "Review what you retained from this chapter."
        let tag = isImage ? "auto study image" : "auto study chapter"

        return Flashcard(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            frontText: candidate.title,
            backText: backText,
            mediaTimestamp: candidate.mediaTimestamp,
            endTimestamp: candidate.endTimestamp,
            triggerTiming: .manualOnly,
            nextReviewDate: nil,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: deckID,
            tags: tag,
            mediaJSON: encodeMedia(imagePath: candidate.imagePath),
            sourceBlockID: candidate.sourceBlockID,
            playlistPosition: candidate.playlistPosition,
            createdAt: nowString,
            modifiedAt: nowString,
            stability: nil,
            difficulty: nil,
            cardType: cardType,
            clozeIndex: nil
        )
    }

    private func encodeMedia(imagePath: String?) -> String? {
        guard let imagePath else { return nil }
        guard let data = try? JSONEncoder().encode(StudyCardMedia(imagePath: imagePath)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
