// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Offers the once-per-chapter "retire the re-listen card?" prompt when the
/// user creates their own card inside an active listening assignment.
struct StudyChapterRetireService {
    let db: DatabaseWriter

    struct RetirePrompt: Identifiable, Equatable, Sendable {
        let assignmentCardID: String
        let assignmentItemID: String
        let chapterTitle: String
        let coveringCardCount: Int

        init(
            assignmentCardID: String,
            assignmentItemID: String,
            chapterTitle: String,
            coveringCardCount: Int = 1
        ) {
            self.assignmentCardID = assignmentCardID
            self.assignmentItemID = assignmentItemID
            self.chapterTitle = chapterTitle
            self.coveringCardCount = coveringCardCount
        }

        var id: String { assignmentCardID }
    }

    func promptForNewUserCard(
        audiobookID: String,
        mediaTimestamp: TimeInterval,
        now: Date = Date()
    ) throws -> RetirePrompt? {
        let nowString = now.ISO8601Format()
        let match: (item: StudyPlanItem, card: Flashcard)? = try db.read { db in
            let plans = try StudyPlan
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_paused") == false)
                .filter(Column("start_date") <= nowString)
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)

            for plan in plans {
                let items = try StudyPlanItem
                    .filter(Column("plan_id") == plan.id)
                    .filter(Column("kind") == StudyPlanItemKind.chapter.rawValue)
                    .filter(Column("is_enabled") == true)
                    .order(Column("ordinal"))
                    .fetchAll(db)

                for item in items {
                    guard let cardID = item.flashcardID,
                        let card = try Flashcard.fetchOne(db, key: cardID),
                        card.isEnabled,
                        card.cardType == StudyFlashcardType.listeningAssignment,
                        card.mediaTimestamp <= mediaTimestamp,
                        mediaTimestamp < (card.endTimestamp ?? .greatestFiniteMagnitude)
                    else { continue }

                    return (item, card)
                }
            }

            return nil
        }

        guard let (item, card) = match else { return nil }
        let media = decodeMedia(card.mediaJSON)
        guard media?.retirePromptShownAt == nil else { return nil }
        if let chapterIndex = item.chapterIndex,
           try hasReleasablePendingCards(planID: item.planID, chapterIndex: chapterIndex) {
            return nil
        }

        try markPromptShown(card: card, existingImagePath: media?.imagePath, now: now)
        return RetirePrompt(
            assignmentCardID: card.id,
            assignmentItemID: item.id,
            chapterTitle: card.frontText
        )
    }

    func promptForDrainedChapter(
        audiobookID: String,
        chapterIndex: Int,
        now: Date = Date()
    ) throws -> RetirePrompt? {
        let nowString = now.ISO8601Format()
        let match: (item: StudyPlanItem, card: Flashcard, coveringCardCount: Int)? = try db.read {
            db in
            let plans = try StudyPlan
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_paused") == false)
                .filter(Column("start_date") <= nowString)
                .order(Column("start_date"), Column("created_at"))
                .fetchAll(db)

            for plan in plans {
                guard try Self.releasablePendingCardCount(
                    planID: plan.id, chapterIndex: chapterIndex, db: db) == 0
                else {
                    continue
                }

                let coveringCardCount = try Self.releasedCardCount(
                    planID: plan.id, chapterIndex: chapterIndex, db: db)
                guard coveringCardCount > 0 else { continue }

                let items = try StudyPlanItem
                    .filter(Column("plan_id") == plan.id)
                    .filter(Column("kind") == StudyPlanItemKind.chapter.rawValue)
                    .filter(Column("chapter_index") == chapterIndex)
                    .filter(Column("is_enabled") == true)
                    .order(Column("ordinal"))
                    .fetchAll(db)

                for item in items {
                    guard let cardID = item.flashcardID,
                        let card = try Flashcard.fetchOne(db, key: cardID),
                        card.isEnabled,
                        card.cardType == StudyFlashcardType.listeningAssignment
                    else { continue }

                    return (item, card, coveringCardCount)
                }
            }

            return nil
        }

        guard let (item, card, coveringCardCount) = match else { return nil }
        let media = decodeMedia(card.mediaJSON)
        guard media?.retirePromptShownAt == nil else { return nil }

        try markPromptShown(card: card, existingImagePath: media?.imagePath, now: now)
        return RetirePrompt(
            assignmentCardID: card.id,
            assignmentItemID: item.id,
            chapterTitle: card.frontText,
            coveringCardCount: coveringCardCount
        )
    }

    func retire(
        assignmentCardID: String,
        assignmentItemID: String,
        now: Date = Date()
    ) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE flashcard SET is_enabled = 0, modified_at = ? WHERE id = ?",
                arguments: [now.ISO8601Format(), assignmentCardID]
            )
        }
        try StudyPlanDAO(db: db).setItemEnabled(
            itemID: assignmentItemID,
            isEnabled: false,
            now: now
        )
    }

    private func markPromptShown(
        card: Flashcard,
        existingImagePath: String?,
        now: Date
    ) throws {
        let media = StudyCardMedia(
            imagePath: existingImagePath,
            retirePromptShownAt: now.ISO8601Format()
        )
        let json = String(decoding: try JSONEncoder().encode(media), as: UTF8.self)

        try db.write { db in
            try db.execute(
                sql: "UPDATE flashcard SET media_json = ?, modified_at = ? WHERE id = ?",
                arguments: [json, now.ISO8601Format(), card.id]
            )
        }
    }

    private func hasReleasablePendingCards(planID: String, chapterIndex: Int) throws -> Bool {
        try db.read { db in
            try Self.releasablePendingCardCount(
                planID: planID,
                chapterIndex: chapterIndex,
                db: db
            ) > 0
        }
    }

    private static func releasablePendingCardCount(
        planID: String,
        chapterIndex: Int,
        db: Database
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM study_plan_item
                JOIN flashcard ON flashcard.id = study_plan_item.flashcard_id
                WHERE study_plan_item.plan_id = ?
                  AND study_plan_item.kind = ?
                  AND study_plan_item.chapter_index = ?
                  AND study_plan_item.introduced_at IS NULL
                  AND study_plan_item.is_enabled = 1
                  AND study_plan_item.flashcard_id IS NOT NULL
                  AND flashcard.is_enabled = 1
                """,
            arguments: [planID, StudyPlanItemKind.card.rawValue, chapterIndex]
        ) ?? 0
    }

    private static func releasedCardCount(
        planID: String,
        chapterIndex: Int,
        db: Database
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM study_plan_item
                JOIN flashcard ON flashcard.id = study_plan_item.flashcard_id
                WHERE study_plan_item.plan_id = ?
                  AND study_plan_item.kind = ?
                  AND study_plan_item.chapter_index = ?
                  AND study_plan_item.introduced_at IS NOT NULL
                  AND study_plan_item.is_enabled = 1
                  AND study_plan_item.flashcard_id IS NOT NULL
                  AND flashcard.is_enabled = 1
                """,
            arguments: [planID, StudyPlanItemKind.card.rawValue, chapterIndex]
        ) ?? 0
    }

    private func decodeMedia(_ json: String?) -> StudyCardMedia? {
        guard let json,
            let data = json.data(using: .utf8)
        else { return nil }

        return try? JSONDecoder().decode(StudyCardMedia.self, from: data)
    }
}
