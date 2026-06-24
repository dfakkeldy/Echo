// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyPlanDAOTests {
    @Test func createsPlanDeckCardsAndItemsTransactionally() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let request = makeRequest(now: now)

        let result = try dao.createPlan(request)

        #expect(result.plan.audiobookID == "book")
        #expect(result.createdCards.count == 2)
        #expect(result.createdItems.count == 2)
        #expect(result.createdCards.allSatisfy { $0.nextReviewDate == nil })
        #expect(result.createdCards.allSatisfy { $0.cardType == StudyFlashcardType.listeningAssignment })
        #expect(result.createdItems.map(\.ordinal) == [0, 1])

        let firstCard = try #require(result.createdCards.first)
        let secondCard = try #require(result.createdCards.dropFirst().first)
        let firstItem = try #require(result.createdItems.first)
        let secondItem = try #require(result.createdItems.dropFirst().first)
        let nowString = now.ISO8601Format()
        #expect(firstCard.deckID == result.plan.deckID)
        #expect(secondCard.deckID == result.plan.deckID)
        #expect(firstCard.sourceBlockID == "book-h1")
        #expect(secondCard.sourceBlockID == "book-h2")
        #expect(firstCard.createdAt == nowString)
        #expect(firstCard.modifiedAt == nowString)
        #expect(firstCard.frontText == "Chapter 1")
        #expect(secondCard.frontText == "Chapter 2")
        #expect(firstCard.backText == "Review what you retained from this chapter.")
        #expect(secondCard.backText == "Review what you retained from this chapter.")
        #expect(firstCard.mediaTimestamp == 10)
        #expect(secondCard.mediaTimestamp == 100)
        #expect(firstCard.endTimestamp == 100)
        #expect(secondCard.endTimestamp == 200)
        #expect(firstItem.flashcardID == firstCard.id)
        #expect(secondItem.flashcardID == secondCard.id)
        #expect(firstItem.sourceBlockID == "book-h1")
        #expect(secondItem.sourceBlockID == "book-h2")
        #expect(firstItem.createdAt == nowString)
        #expect(firstItem.modifiedAt == nowString)

        let counts = try rowCounts(in: service)
        let timelineRows = try generatedTimelineRows(in: service)
        #expect(counts.decks == 1)
        #expect(counts.studyPlans == 1)
        #expect(counts.flashcards == 2)
        #expect(counts.studyPlanItems == 2)
        #expect(timelineRows == [
            "ankiCard-\(firstCard.id)|\(firstCard.id)|true",
            "ankiCard-\(secondCard.id)|\(secondCard.id)|true",
        ])
    }

    @Test func fetchesPlanByBook() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        _ = try dao.createPlan(makeRequest())

        let plan = try dao.plan(for: "book")

        #expect(plan?.audiobookID == "book")
        #expect(plan?.newChapterLimit == 1)
    }

    @Test func marksItemsIntroduced() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let result = try dao.createPlan(makeRequest())
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        try dao.markIntroduced(itemIDs: [result.createdItems[0].id], now: now)

        let items = try dao.items(for: result.plan.id)
        #expect(items[0].introducedAt == now.ISO8601Format())
        #expect(items[1].introducedAt == nil)
    }

    @Test func updatesSettingsPauseStateAndItemEnabledState() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let result = try dao.createPlan(makeRequest(newChapterLimit: 0))

        try dao.updateSettings(
            planID: result.plan.id,
            cadenceUnit: .week,
            newChapterLimit: 2,
            includeImages: true,
            queueMode: .mixed,
            catchUpPolicy: .strict
        )
        try dao.setPaused(planID: result.plan.id, isPaused: true)
        try dao.setItemEnabled(itemID: result.createdItems[0].id, isEnabled: false)

        let plan = try #require(try dao.plan(for: "book"))
        let items = try dao.items(for: result.plan.id)
        #expect(result.plan.newChapterLimit == 1)
        #expect(plan.cadenceUnit == StudyPlanCadenceUnit.week.rawValue)
        #expect(plan.newChapterLimit == 2)
        #expect(plan.includeImages)
        #expect(plan.queueModeDefault == StudyPlanQueueMode.mixed.rawValue)
        #expect(plan.catchUpPolicy == StudyPlanCatchUpPolicy.strict.rawValue)
        #expect(plan.isPaused)
        #expect(items[0].isEnabled == false)
    }

    @Test func activePlansExcludesPausedPlans() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let first = try dao.createPlan(makeRequest())
        try seedBook(id: "second-book", title: "Second Book", in: service)
        let second = try dao.createPlan(makeRequest(audiobookID: "second-book", bookTitle: "Second Book"))

        try dao.setPaused(planID: first.plan.id, isPaused: true)

        #expect(try dao.activePlans().map(\.id) == [second.plan.id])
    }

    @Test func createsImageAssignmentsWithMediaJSON() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let result = try dao.createPlan(makeImageRequest())

        let card = try #require(result.createdCards.first)
        let mediaJSON = try #require(card.mediaJSON)
        let media = try JSONDecoder().decode(StudyCardMedia.self, from: Data(mediaJSON.utf8))

        #expect(card.cardType == StudyFlashcardType.imageAssignment)
        #expect(card.tags == "auto study image")
        #expect(media.imagePath == "Images/map.png")
        #expect(result.createdItems.first?.kind == StudyPlanItemKind.image.rawValue)
    }

    @Test func retriesExistingBookWithoutCreatingEmptyDuplicatePlan() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let original = try dao.createPlan(makeRequest())
        let countsAfterCreate = try rowCounts(in: service)

        let retryNow = Date(timeIntervalSince1970: 1_750_000_600)
        let result = try dao.createPlan(
            makeRequest(includeSecondChapterByDefault: false, now: retryNow)
        )
        let countsAfterRetry = try rowCounts(in: service)
        let currentPlan = try #require(try dao.plan(for: "book"))
        let currentItems = try dao.items(for: currentPlan.id)
        let activePlans = try dao.activePlans()

        #expect(result.plan == original.plan)
        #expect(result.createdCards.isEmpty)
        #expect(result.createdItems.isEmpty)
        #expect(countsAfterRetry.studyPlans == countsAfterCreate.studyPlans)
        #expect(countsAfterRetry.decks == countsAfterCreate.decks)
        #expect(countsAfterRetry.flashcards == countsAfterCreate.flashcards)
        #expect(countsAfterRetry.studyPlanItems == countsAfterCreate.studyPlanItems)
        #expect(currentPlan.id == original.plan.id)
        #expect(currentItems.map(\.id) == original.createdItems.map(\.id))
        #expect(activePlans.map(\.id) == [original.plan.id])
    }

    @Test func rollsBackPlanDeckCardsAndItemsWhenItemInsertFails() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let request = makeRequest(extraMissingSourceCandidate: true)

        #expect(throws: (any Error).self) {
            try dao.createPlan(request)
        }

        let counts = try rowCounts(in: service)
        #expect(counts.decks == 0)
        #expect(counts.studyPlans == 0)
        #expect(counts.flashcards == 0)
        #expect(counts.studyPlanItems == 0)
    }

    private func rowCounts(
        in service: DatabaseService
    ) throws -> (decks: Int, studyPlans: Int, flashcards: Int, studyPlanItems: Int) {
        try service.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deck") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM study_plan") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM flashcard") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM study_plan_item") ?? 0
            )
        }
    }

    private func generatedTimelineRows(in service: DatabaseService) throws -> [String] {
        try service.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_rowid, is_enabled
                    FROM timeline_item
                    WHERE source_table = 'flashcard'
                    ORDER BY audio_start_time, source_rowid
                    """
            )
            .map { row in
                let id = row["id"] as String
                let sourceRowID = row["source_rowid"] as String
                let isEnabled = row["is_enabled"] as Bool
                return "\(id)|\(sourceRowID)|\(isEnabled)"
            }
        }
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try seedBook(id: "book", title: "Study Book", in: service)
        return service
    }

    private func seedBook(id: String, title: String, in service: DatabaseService) throws {
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, ?, 3600, '2026-06-01T00:00:00Z')
                    """,
                arguments: [id, title]
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                    ) VALUES
                    (?, ?, 'ch1.xhtml', 0, 0, 0, 'heading', 'Chapter 1', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    (?, ?, 'ch2.xhtml', 1, 0, 1, 'heading', 'Chapter 2', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    (?, ?, 'ch2.xhtml', 1, 1, 2, 'image', NULL, 'Images/map.png', 1, 0, 0, '2026-06-01T00:00:00Z')
                    """,
                arguments: [
                    "\(id)-h1", id,
                    "\(id)-h2", id,
                    "\(id)-img1", id,
                ]
            )
        }
    }

    private func makeRequest(
        audiobookID: String = "book",
        bookTitle: String = "Study Book",
        newChapterLimit: Int = 1,
        includeSecondChapterByDefault: Bool = true,
        extraMissingSourceCandidate: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> StudyPlanCreationRequest {
        var candidates = [
            StudyPlanCandidate(
                id: "chapter-\(audiobookID)-h1",
                kind: .chapter,
                sourceBlockID: "\(audiobookID)-h1",
                chapterIndex: 0,
                ordinal: 0,
                title: "Chapter 1",
                defaultIncluded: true,
                imagePath: nil,
                mediaTimestamp: 10,
                endTimestamp: 100,
                playlistPosition: nil
            ),
            StudyPlanCandidate(
                id: "chapter-\(audiobookID)-h2",
                kind: .chapter,
                sourceBlockID: "\(audiobookID)-h2",
                chapterIndex: 1,
                ordinal: 1,
                title: "Chapter 2",
                defaultIncluded: includeSecondChapterByDefault,
                imagePath: nil,
                mediaTimestamp: 100,
                endTimestamp: 200,
                playlistPosition: nil
            ),
        ]

        if extraMissingSourceCandidate {
            candidates.append(
                StudyPlanCandidate(
                    id: "chapter-missing",
                    kind: .chapter,
                    sourceBlockID: "missing-source",
                    chapterIndex: 2,
                    ordinal: 2,
                    title: "Missing Source",
                    defaultIncluded: true,
                    imagePath: nil,
                    mediaTimestamp: 200,
                    endTimestamp: 300,
                    playlistPosition: nil
                )
            )
        }

        return StudyPlanCreationRequest(
            audiobookID: audiobookID,
            bookTitle: bookTitle,
            cadenceUnit: .day,
            newChapterLimit: newChapterLimit,
            includeImages: false,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            startDate: now,
            candidates: candidates,
            now: now
        )
    }

    private func makeImageRequest(
        now: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> StudyPlanCreationRequest {
        StudyPlanCreationRequest(
            audiobookID: "book",
            bookTitle: "Study Book",
            cadenceUnit: .day,
            newChapterLimit: 1,
            includeImages: true,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            startDate: now,
            candidates: [
                StudyPlanCandidate(
                    id: "image-book-img1",
                    kind: .image,
                    sourceBlockID: "book-img1",
                    chapterIndex: 1,
                    ordinal: 1,
                    title: "Review this image from Chapter 2.",
                    defaultIncluded: true,
                    imagePath: "Images/map.png",
                    mediaTimestamp: 100,
                    endTimestamp: nil,
                    playlistPosition: nil
                ),
            ],
            now: now
        )
    }
}
