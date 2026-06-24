// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyQueueBuilder {
    let db: DatabaseWriter

    func build(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil
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
        let assignmentQueueEntries = plans.flatMap { plan in
            assignmentEntries(
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
        let orderedEntries = ordered(entries: dueEntries + assignmentQueueEntries, mode: mode, planOrder: planOrder)

        return StudyQueue(entries: orderedEntries)
    }

    private func assignmentEntries(
        for plan: StudyPlan,
        rows: [ItemCardRow],
        now: Date,
        calendar: Calendar
    ) -> [StudyQueueEntry] {
        let inProgress = rows
            .filter { row in
                row.item.introducedAt != nil
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

        let budget = releaseBudget(plan: plan, rows: rows, now: now, calendar: calendar)
        guard budget > 0 else {
            return inProgress
        }

        let pendingChapters = Array(
            rows
                .filter { row in
                    row.item.introducedAt == nil
                        && row.item.kind == StudyPlanItemKind.chapter.rawValue
                }
                .prefix(budget)
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

    private func releaseBudget(
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
            let introducedThisWindow = introducedChapterCount(
                rows: rows,
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
            let introducedTotal = introducedChapterCount(rows: rows, after: startDate, through: now)
            return max(0, allowedChapterCount - introducedTotal)
        }
    }

    private func introducedChapterCount(
        rows: [ItemCardRow],
        after startDate: Date,
        through endDate: Date
    ) -> Int {
        rows.filter { row in
            guard row.item.kind == StudyPlanItemKind.chapter.rawValue,
                  let introducedAt = row.item.introducedAt,
                  let introducedDate = try? Date(introducedAt, strategy: .iso8601) else {
                return false
            }
            return introducedDate >= startDate && introducedDate <= endDate
        }.count
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
