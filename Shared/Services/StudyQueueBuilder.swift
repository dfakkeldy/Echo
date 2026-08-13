// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyQueueBuilder {
    let db: DatabaseWriter

    func build(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil,
        globalNewChapterLimit: Int? = nil,
        globalNewCardLimit: Int? = nil
    ) throws -> StudyQueue {
        let dueCards = try FlashcardDAO(db: db).allDueCards(now: now)
        let plans = try StudyPlanDAO(db: db).plansForQueue()
        let planOrder = Dictionary(uniqueKeysWithValues: plans.enumerated().map { ($0.element.id, $0.offset) })
        let itemRowsByPlanID = try Dictionary(
            uniqueKeysWithValues: plans.map { plan in
                (plan.id, try itemCardRows(planID: plan.id))
            }
        )

        let dueEntries = dueEntries(
            for: dueCards,
            plans: plans,
            itemRowsByPlanID: itemRowsByPlanID
        )
        let assignmentQueueEntries = try plans.flatMap { plan in
            try assignmentEntries(
                for: plan,
                rows: itemRowsByPlanID[plan.id] ?? [],
                now: now,
                calendar: calendar
            )
        }
        let newCardQueueEntries = try plans.flatMap { plan in
            try newCardEntries(
                for: plan,
                rows: itemRowsByPlanID[plan.id] ?? [],
                now: now,
                calendar: calendar
            )
        }
        let modeSourcePlan = plans.first { !$0.isPaused } ?? plans.first
        let mode = modeOverride
            ?? modeSourcePlan.flatMap { StudyPlanQueueMode(rawValue: $0.queueModeDefault) }
            ?? .bookByBook
        let orderedEntries = ordered(
            entries: dueEntries + assignmentQueueEntries + newCardQueueEntries,
            mode: mode,
            planOrder: planOrder
        )
        let chapterCappedEntries = applyGlobalNewChapterLimit(globalNewChapterLimit, to: orderedEntries)
        let cappedEntries = applyGlobalNewCardLimit(globalNewCardLimit, to: chapterCappedEntries)

        return StudyQueue(entries: cappedEntries)
    }

    private func assignmentEntries(
        for plan: StudyPlan,
        rows: [ItemCardRow],
        now: Date,
        calendar: Calendar
    ) throws -> [StudyQueueEntry] {
        let inProgress = rows
            .filter { row in
                row.item.introducedAt != nil
                    && row.item.kind != StudyPlanItemKind.card.rawValue
                    && row.card.repetitions == 0
                    && row.card.lastReviewedAt == nil
            }
            .map { row in
                StudyQueueEntry(
                    id: "progress-\(row.item.id)",
                    category: .inProgressAssignment,
                    plan: plan,
                    item: row.item,
                    flashcard: row.card
                )
            }

        guard !plan.isPaused else {
            return inProgress
        }

        let budget = chapterReleaseBudget(plan: plan, rows: rows, now: now, calendar: calendar)
        guard budget > 0 else {
            return inProgress
        }

        let hasCardItems = try planHasCardItems(planID: plan.id)
        let chapterPacing = StudyPlanChapterPacing(rawValue: plan.chapterPacing) ?? .cardDrain
        if chapterPacing == .cardDrain,
           try frontierHasReleasablePendingCards(planID: plan.id, rows: rows) {
            return inProgress
        }

        let effectiveBudget = chapterPacing == .cardDrain && hasCardItems
            ? min(budget, 1)
            : budget
        let pendingChapters = Array(
            rows
                .filter { row in
                    row.item.introducedAt == nil
                        && row.item.kind == StudyPlanItemKind.chapter.rawValue
                }
                .prefix(effectiveBudget)
        )
        let pendingChapterIndexes = Set(pendingChapters.compactMap(\.item.chapterIndex))
        let pendingImages = rows.filter { row in
            row.item.introducedAt == nil
                && row.item.kind == StudyPlanItemKind.image.rawValue
                && row.item.chapterIndex.map { pendingChapterIndexes.contains($0) } == true
        }

        let newEntries = (pendingChapters + pendingImages)
            .sorted { left, right in
                left.item.ordinal < right.item.ordinal
            }
            .map { row in
                StudyQueueEntry(
                    id: "new-\(row.item.id)",
                    category: .newAssignment,
                    plan: plan,
                    item: row.item,
                    flashcard: row.card
                )
            }

        return inProgress + newEntries
    }

    private func dueEntries(
        for dueCards: [Flashcard],
        plans: [StudyPlan],
        itemRowsByPlanID: [String: [ItemCardRow]]
    ) -> [StudyQueueEntry] {
        let plansByID = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
        let plansByAudiobookID = Dictionary(plans.map { ($0.audiobookID, $0) }, uniquingKeysWith: { first, _ in first })
        let plansByDeckID = Dictionary(
            plans.compactMap { plan in plan.deckID.map { ($0, plan) } },
            uniquingKeysWith: { first, _ in first }
        )
        let rowsByFlashcardID = Dictionary(
            itemRowsByPlanID.flatMap { planID, rows in
                rows.compactMap { row in
                    row.item.flashcardID.map { ($0, (planID: planID, row: row)) }
                }
            },
            uniquingKeysWith: { first, _ in first }
        )

        return dueCards.map { card in
            let linkedRow = rowsByFlashcardID[card.id]
            let linkedPlan = linkedRow.flatMap { plansByID[$0.planID] }
            let fallbackPlan = plansByAudiobookID[card.audiobookID]
                ?? card.deckID.flatMap { plansByDeckID[$0] }

            return StudyQueueEntry(
                id: "due-\(card.id)",
                category: .dueReview,
                plan: linkedPlan ?? fallbackPlan,
                item: linkedRow?.row.item,
                flashcard: card
            )
        }
    }

    private func chapterReleaseBudget(
        plan: StudyPlan,
        rows: [ItemCardRow],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let limit = max(1, plan.newChapterLimit)
        guard let startDate = try? Date(plan.startDate, strategy: .iso8601),
              startDate <= now else {
            return 0
        }

        let unit = StudyPlanCadenceUnit(rawValue: plan.cadenceUnit) ?? .day
        let catchUpPolicy = StudyPlanCatchUpPolicy(rawValue: plan.catchUpPolicy) ?? .gentle

        switch catchUpPolicy {
        case .gentle:
            let windowStart = max(
                startDate,
                cadenceWindowStart(for: unit, containing: now, calendar: calendar)
            )
            let introducedThisWindow = introducedItemCount(
                rows: rows,
                kind: .chapter,
                after: windowStart,
                through: now
            )
            return max(0, limit - introducedThisWindow)

        case .strict:
            let allowedChapterCount = limit * elapsedCadenceWindowCount(
                from: startDate,
                through: now,
                unit: unit,
                calendar: calendar
            )
            let introducedTotal = introducedItemCount(
                rows: rows, kind: .chapter, after: startDate, through: now)
            return max(0, allowedChapterCount - introducedTotal)
        }
    }

    func remainingNewCardBudget(
        plan: StudyPlan,
        now: Date = Date(),
        calendar: Calendar = .current,
        globalNewCardLimit: Int? = nil
    ) throws -> Int {
        let rows = try itemCardRows(planID: plan.id)
        let planBudget = cardReleaseBudget(plan: plan, rows: rows, now: now, calendar: calendar)
        let globalBudget = globalNewCardLimit.map { max(0, $0) } ?? Int.max
        return min(planBudget, globalBudget)
    }

    private func newCardEntries(
        for plan: StudyPlan,
        rows: [ItemCardRow],
        now: Date,
        calendar: Calendar
    ) throws -> [StudyQueueEntry] {
        guard !plan.isPaused else { return [] }

        let budget = cardReleaseBudget(plan: plan, rows: rows, now: now, calendar: calendar)
        guard budget > 0 else { return [] }

        let introducedChapters = try introducedChapterIndexes(planID: plan.id)
        let pendingCards = rows
            .filter { row in
                row.item.kind == StudyPlanItemKind.card.rawValue
                    && row.item.introducedAt == nil
                    && row.item.chapterIndex.map { introducedChapters.contains($0) } == true
            }
            .sorted { $0.item.ordinal < $1.item.ordinal }
            .prefix(budget)

        return pendingCards.map { row in
            StudyQueueEntry(
                id: "card-\(row.item.id)",
                category: .newCard,
                plan: plan,
                item: row.item,
                flashcard: row.card
            )
        }
    }

    private func cardReleaseBudget(
        plan: StudyPlan,
        rows: [ItemCardRow],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let limit = max(1, plan.newCardsPerDay)
        guard let startDate = try? Date(plan.startDate, strategy: .iso8601),
              startDate <= now else {
            return 0
        }

        let catchUpPolicy = StudyPlanCatchUpPolicy(rawValue: plan.catchUpPolicy) ?? .gentle

        switch catchUpPolicy {
        case .gentle:
            let windowStart = max(
                startDate,
                cadenceWindowStart(for: .day, containing: now, calendar: calendar)
            )
            let introducedThisWindow = introducedItemCount(
                rows: rows,
                kind: .card,
                after: windowStart,
                through: now
            )
            return max(0, limit - introducedThisWindow)

        case .strict:
            let allowedCardCount = limit * elapsedCadenceWindowCount(
                from: startDate,
                through: now,
                unit: .day,
                calendar: calendar
            )
            let introducedTotal = introducedItemCount(
                rows: rows, kind: .card, after: startDate, through: now)
            return max(0, allowedCardCount - introducedTotal)
        }
    }

    private func introducedItemCount(
        rows: [ItemCardRow],
        kind: StudyPlanItemKind,
        after startDate: Date,
        through endDate: Date
    ) -> Int {
        rows.filter { row in
            guard row.item.kind == kind.rawValue,
                  let introducedAt = row.item.introducedAt,
                  let introducedDate = try? Date(introducedAt, strategy: .iso8601) else {
                return false
            }
            return introducedDate >= startDate && introducedDate <= endDate
        }.count
    }

    private func frontierHasReleasablePendingCards(
        planID: String,
        rows: [ItemCardRow]
    ) throws -> Bool {
        guard let frontierChapterIndex = try frontierIntroducedChapterIndex(planID: planID) else {
            return false
        }

        return rows.contains { row in
            row.item.kind == StudyPlanItemKind.card.rawValue
                && row.item.introducedAt == nil
                && row.item.chapterIndex == frontierChapterIndex
        }
    }

    private func planHasCardItems(planID: String) throws -> Bool {
        try db.read { db in
            let count = try StudyPlanItem
                .filter(Column("plan_id") == planID)
                .filter(Column("kind") == StudyPlanItemKind.card.rawValue)
                .fetchCount(db)
            return count > 0
        }
    }

    private func frontierIntroducedChapterIndex(planID: String) throws -> Int? {
        try db.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT chapter_index FROM study_plan_item
                    WHERE plan_id = ?
                      AND kind = ?
                      AND introduced_at IS NOT NULL
                      AND chapter_index IS NOT NULL
                    ORDER BY ordinal DESC
                    LIMIT 1
                    """,
                arguments: [planID, StudyPlanItemKind.chapter.rawValue]
            )
        }
    }

    private func introducedChapterIndexes(planID: String) throws -> Set<Int> {
        try db.read { db in
            let indexes = try Int.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT chapter_index FROM study_plan_item
                    WHERE plan_id = ?
                      AND kind = ?
                      AND introduced_at IS NOT NULL
                      AND chapter_index IS NOT NULL
                    """,
                arguments: [planID, StudyPlanItemKind.chapter.rawValue]
            )
            return Set(indexes)
        }
    }

    private func cadenceWindowStart(
        for unit: StudyPlanCadenceUnit,
        containing date: Date,
        calendar: Calendar
    ) -> Date {
        switch unit {
        case .day:
            calendar.startOfDay(for: date)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    private func elapsedCadenceWindowCount(
        from startDate: Date,
        through endDate: Date,
        unit: StudyPlanCadenceUnit,
        calendar: Calendar
    ) -> Int {
        let start = cadenceWindowStart(for: unit, containing: startDate, calendar: calendar)
        let end = cadenceWindowStart(for: unit, containing: endDate, calendar: calendar)

        switch unit {
        case .day:
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            return max(1, days + 1)
        case .week:
            let weeks = calendar.dateComponents([.weekOfYear], from: start, to: end).weekOfYear ?? 0
            return max(1, weeks + 1)
        }
    }

    private func ordered(
        entries: [StudyQueueEntry],
        mode: StudyPlanQueueMode,
        planOrder: [String: Int]
    ) -> [StudyQueueEntry] {
        entries.sorted { left, right in
            switch mode {
            case .bookByBook:
                let leftPlanOrder = left.plan.map { planOrder[$0.id] ?? Int.max } ?? Int.max
                let rightPlanOrder = right.plan.map { planOrder[$0.id] ?? Int.max } ?? Int.max
                if leftPlanOrder != rightPlanOrder {
                    return leftPlanOrder < rightPlanOrder
                }
                if left.category != right.category {
                    return left.category.rawValue < right.category.rawValue
                }
                return orderedWithinCategory(left, before: right)

            case .mixed:
                if left.category != right.category {
                    return left.category.rawValue < right.category.rawValue
                }
                if orderedWithinCategory(left, before: right) {
                    return true
                }
                if orderedWithinCategory(right, before: left) {
                    return false
                }
                let leftPlanOrder = left.plan.map { planOrder[$0.id] ?? Int.max } ?? Int.max
                let rightPlanOrder = right.plan.map { planOrder[$0.id] ?? Int.max } ?? Int.max
                return leftPlanOrder < rightPlanOrder
            }
        }
    }

    private func orderedWithinCategory(_ left: StudyQueueEntry, before right: StudyQueueEntry) -> Bool {
        if left.category == .dueReview {
            let leftDate = left.flashcard.nextReviewDate ?? ""
            let rightDate = right.flashcard.nextReviewDate ?? ""
            if leftDate != rightDate {
                return leftDate < rightDate
            }
        }

        let leftOrdinal = left.item?.ordinal ?? Int.max
        let rightOrdinal = right.item?.ordinal ?? Int.max
        if leftOrdinal != rightOrdinal {
            return leftOrdinal < rightOrdinal
        }

        let leftFallback = left.flashcard.createdAt ?? left.flashcard.id
        let rightFallback = right.flashcard.createdAt ?? right.flashcard.id
        return leftFallback < rightFallback
    }

    private func applyGlobalNewChapterLimit(
        _ limit: Int?,
        to entries: [StudyQueueEntry]
    ) -> [StudyQueueEntry] {
        guard let limit else { return entries }

        let effectiveLimit = max(0, limit)
        var releasedChapterCount = 0
        var releasedChapterKeys: Set<AssignmentChapterKey> = []

        return entries.filter { entry in
            guard entry.category == .newAssignment,
                  let item = entry.item,
                  let kind = StudyPlanItemKind(rawValue: item.kind) else {
                return true
            }

            switch kind {
            case .chapter:
                guard releasedChapterCount < effectiveLimit else { return false }
                releasedChapterCount += 1
                if let key = AssignmentChapterKey(item: item) {
                    releasedChapterKeys.insert(key)
                }
                return true

            case .image:
                guard let key = AssignmentChapterKey(item: item) else { return false }
                return releasedChapterKeys.contains(key)
            case .card:
                return true
            }
        }
    }

    private func applyGlobalNewCardLimit(
        _ limit: Int?,
        to entries: [StudyQueueEntry]
    ) -> [StudyQueueEntry] {
        guard let limit else { return entries }

        let effectiveLimit = max(0, limit)
        var releasedCardCount = 0

        return entries.filter { entry in
            guard entry.category == .newCard else { return true }
            guard releasedCardCount < effectiveLimit else { return false }
            releasedCardCount += 1
            return true
        }
    }

    private struct AssignmentChapterKey: Hashable {
        let planID: String
        let chapterIndex: Int

        init?(item: StudyPlanItem) {
            guard let chapterIndex = item.chapterIndex else { return nil }
            self.planID = item.planID
            self.chapterIndex = chapterIndex
        }
    }

    private struct ItemCardRow {
        let item: StudyPlanItem
        let card: Flashcard
    }

    private func itemCardRows(planID: String) throws -> [ItemCardRow] {
        try db.read { db in
            let items = try StudyPlanItem
                .filter(Column("plan_id") == planID)
                .filter(Column("is_enabled") == true)
                .order(Column("ordinal"))
                .fetchAll(db)
            let cardIDs = items.compactMap(\.flashcardID)
            guard !cardIDs.isEmpty else {
                return []
            }

            let cards = try Flashcard
                .filter(cardIDs.contains(Column("id")))
                .filter(Column("is_enabled") == true)
                .fetchAll(db)
            let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })

            return items.compactMap { item in
                guard let flashcardID = item.flashcardID,
                      let card = cardsByID[flashcardID] else {
                    return nil
                }
                return ItemCardRow(item: item, card: card)
            }
        }
    }
}
