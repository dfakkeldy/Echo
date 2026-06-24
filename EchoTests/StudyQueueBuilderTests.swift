// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyQueueBuilderTests {
    @Test func dueReviewsPrecedeInProgressAndNewAssignments() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.entries.map(\.category) == [.dueReview, .inProgressAssignment, .newAssignment])
    }

    @Test func dayCadenceIntroducesConfiguredChapterCount() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.newAssignmentCount == 1)
    }

    @Test func weekCadenceIntroducesConfiguredChapterCountForWeekWindow() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(cadenceUnit: .week, chapterLimit: 2)
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.newAssignmentCount == 2)
    }

    @Test func gentleCatchUpDoesNotPileUpMissedChapters() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1, startDaysBeforeNow: 7)
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(queue.newAssignmentCount == 1)
    }

    @Test func mixedModePreservesNewAssignmentOrderPerBook() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlans()
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            modeOverride: .mixed
        )
        let newCards = queue.entries.filter { $0.category == .newAssignment }.map(\.flashcard.frontText)

        #expect(newCards == ["Book A Chapter 1", "Book B Chapter 1"])
    }

    @Test func dueReviewsExcludeDisabledAndUnscheduledCards() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyQueueFixtures.seedDueCard(
            id: "disabled-due",
            audiobookID: "book-a",
            frontText: "Disabled Due Review",
            nextReviewDate: StudyQueueFixtures.mondayNoon.addingTimeInterval(-60),
            isEnabled: false,
            in: service
        )
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        let dueCards = queue.entries.filter { $0.category == .dueReview }.map(\.flashcard.frontText)

        #expect(dueCards == ["Due Review"])
    }

    @Test func imageAssignmentsReleaseWithContainingChapterWithoutConsumingChapterBudget() throws {
        let service = try StudyQueueFixtures.serviceWithImagePlan(chapterLimit: 1)
        let builder = StudyQueueBuilder(db: service.writer)

        let queue = try builder.build(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        let newCards = queue.entries.filter { $0.category == .newAssignment }.map(\.flashcard.frontText)

        #expect(newCards == ["Book A Chapter 1", "Book A Image 1"])
        #expect(queue.newAssignmentCount == 2)
    }
}

private enum StudyQueueFixtures {
    static let mondayNoon = Date(timeIntervalSince1970: 1_782_129_600)
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }()

    static func serviceWithPlan(
        cadenceUnit: StudyPlanCadenceUnit = .day,
        chapterLimit: Int = 1,
        startDaysBeforeNow: Int = 0
    ) throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try seedBook(id: "book-a", title: "Book A", in: service)

        let request = makeRequest(
            audiobookID: "book-a",
            bookTitle: "Book A",
            cadenceUnit: cadenceUnit,
            chapterLimit: chapterLimit,
            startDaysBeforeNow: startDaysBeforeNow
        )
        let result = try StudyPlanDAO(db: service.writer).createPlan(request)

        try markIntroduced(result.createdItems[0], at: mondayNoon.addingTimeInterval(-86_400), in: service)
        try seedDueCard(
            id: "due",
            audiobookID: "book-a",
            frontText: "Due Review",
            nextReviewDate: mondayNoon.addingTimeInterval(-3_600),
            isEnabled: true,
            in: service
        )

        return service
    }

    static func serviceWithTwoPlans() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try seedBook(id: "book-a", title: "Book A", in: service)
        try seedBook(id: "book-b", title: "Book B", in: service)

        _ = try StudyPlanDAO(db: service.writer).createPlan(
            makeRequest(audiobookID: "book-a", bookTitle: "Book A", chapterLimit: 1)
        )
        _ = try StudyPlanDAO(db: service.writer).createPlan(
            makeRequest(audiobookID: "book-b", bookTitle: "Book B", chapterLimit: 1)
        )

        return service
    }

    static func serviceWithImagePlan(chapterLimit: Int) throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try seedBook(id: "book-a", title: "Book A", includeImage: true, in: service)

        _ = try StudyPlanDAO(db: service.writer).createPlan(
            makeRequest(
                audiobookID: "book-a",
                bookTitle: "Book A",
                chapterLimit: chapterLimit,
                includeImages: true
            )
        )

        return service
    }

    static func seedDueCard(
        id: String,
        audiobookID: String,
        frontText: String,
        nextReviewDate: Date,
        isEnabled: Bool,
        in service: DatabaseService
    ) throws {
        let stamp = mondayNoon.ISO8601Format()
        try FlashcardDAO(db: service.writer).insert(
            Flashcard(
                id: id,
                audiobookID: audiobookID,
                frontText: frontText,
                backText: "Back",
                mediaTimestamp: 0,
                endTimestamp: nil,
                triggerTiming: .manualOnly,
                nextReviewDate: nextReviewDate.ISO8601Format(),
                intervalDays: 1,
                easeFactor: 2.5,
                repetitions: 1,
                lastReviewedAt: mondayNoon.addingTimeInterval(-172_800).ISO8601Format(),
                lastGrade: 3,
                isEnabled: isEnabled,
                deckID: nil,
                tags: nil,
                mediaJSON: nil,
                sourceBlockID: nil,
                playlistPosition: nil,
                createdAt: stamp,
                modifiedAt: stamp,
                stability: nil,
                difficulty: nil,
                cardType: StudyFlashcardType.normal,
                clozeIndex: nil
            )
        )
    }

    private static func seedBook(
        id: String,
        title: String,
        includeImage: Bool = false,
        in service: DatabaseService
    ) throws {
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, ?, 3600, ?)
                    """,
                arguments: [id, title, mondayNoon.ISO8601Format()]
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                    ) VALUES
                    (?, ?, 'ch1.xhtml', 0, 0, 0, 'heading', ?, NULL, 0, 0, 0, ?),
                    (?, ?, 'ch2.xhtml', 1, 0, 2, 'heading', ?, NULL, 1, 0, 0, ?),
                    (?, ?, 'ch3.xhtml', 2, 0, 3, 'heading', ?, NULL, 2, 0, 0, ?)
                    """,
                arguments: [
                    "\(id)-h1", id, "\(title) Chapter 1", mondayNoon.ISO8601Format(),
                    "\(id)-h2", id, "\(title) Chapter 2", mondayNoon.ISO8601Format(),
                    "\(id)-h3", id, "\(title) Chapter 3", mondayNoon.ISO8601Format(),
                ]
            )

            if includeImage {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block (
                            id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                            block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                        ) VALUES
                        (?, ?, 'ch1.xhtml', 0, 1, 1, 'image', NULL, 'Images/one.png', 0, 0, 0, ?)
                        """,
                    arguments: ["\(id)-img1", id, mondayNoon.ISO8601Format()]
                )
            }
        }
    }

    private static func markIntroduced(_ item: StudyPlanItem, at date: Date, in service: DatabaseService) throws {
        try service.write { db in
            try db.execute(
                sql: """
                    UPDATE study_plan_item
                    SET introduced_at = ?, modified_at = ?
                    WHERE id = ?
                    """,
                arguments: [date.ISO8601Format(), date.ISO8601Format(), item.id]
            )
        }
    }

    private static func makeRequest(
        audiobookID: String,
        bookTitle: String,
        cadenceUnit: StudyPlanCadenceUnit = .day,
        chapterLimit: Int,
        startDaysBeforeNow: Int = 0,
        includeImages: Bool = false
    ) -> StudyPlanCreationRequest {
        let startDate = mondayNoon.addingTimeInterval(-Double(startDaysBeforeNow) * 86_400)
        let candidates = makeCandidates(audiobookID: audiobookID, bookTitle: bookTitle, includeImages: includeImages)

        return StudyPlanCreationRequest(
            audiobookID: audiobookID,
            bookTitle: bookTitle,
            cadenceUnit: cadenceUnit,
            newChapterLimit: chapterLimit,
            includeImages: includeImages,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            startDate: startDate,
            candidates: candidates,
            now: startDate
        )
    }

    private static func makeCandidates(
        audiobookID: String,
        bookTitle: String,
        includeImages: Bool
    ) -> [StudyPlanCandidate] {
        var candidates = [
            StudyPlanCandidate(
                id: "chapter-\(audiobookID)-h1",
                kind: .chapter,
                sourceBlockID: "\(audiobookID)-h1",
                chapterIndex: 0,
                ordinal: 0,
                title: "\(bookTitle) Chapter 1",
                defaultIncluded: true,
                imagePath: nil,
                mediaTimestamp: 0,
                endTimestamp: 100,
                playlistPosition: nil
            ),
            StudyPlanCandidate(
                id: "chapter-\(audiobookID)-h2",
                kind: .chapter,
                sourceBlockID: "\(audiobookID)-h2",
                chapterIndex: 1,
                ordinal: includeImages ? 2 : 1,
                title: "\(bookTitle) Chapter 2",
                defaultIncluded: true,
                imagePath: nil,
                mediaTimestamp: 100,
                endTimestamp: 200,
                playlistPosition: nil
            ),
            StudyPlanCandidate(
                id: "chapter-\(audiobookID)-h3",
                kind: .chapter,
                sourceBlockID: "\(audiobookID)-h3",
                chapterIndex: 2,
                ordinal: includeImages ? 3 : 2,
                title: "\(bookTitle) Chapter 3",
                defaultIncluded: true,
                imagePath: nil,
                mediaTimestamp: 200,
                endTimestamp: 300,
                playlistPosition: nil
            ),
        ]

        if includeImages {
            candidates.insert(
                StudyPlanCandidate(
                    id: "image-\(audiobookID)-img1",
                    kind: .image,
                    sourceBlockID: "\(audiobookID)-img1",
                    chapterIndex: 0,
                    ordinal: 1,
                    title: "\(bookTitle) Image 1",
                    defaultIncluded: true,
                    imagePath: "Images/one.png",
                    mediaTimestamp: 20,
                    endTimestamp: nil,
                    playlistPosition: nil
                ),
                at: 1
            )
        }

        return candidates
    }
}
