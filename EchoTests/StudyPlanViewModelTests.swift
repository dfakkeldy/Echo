// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyPlanViewModelTests {
    @Test func createPlanHonorsDeselectedCandidates() throws {
        let service = try seededService()
        let viewModel = StudyPlanViewModel(audiobookID: "book", bookTitle: "Study Book", db: service.writer)
        viewModel.load()

        #expect(viewModel.candidates.map(\.sourceBlockID) == ["h1", "h2", "h3"])
        let secondCandidate = try #require(viewModel.candidates.dropFirst().first)
        viewModel.toggleCandidate(secondCandidate)

        let didSave = viewModel.save(now: Self.testDate)

        #expect(didSave)
        #expect(viewModel.existingPlan != nil)
        let createdSources = try flashcardSourceBlockIDs(in: service)
        #expect(createdSources == ["h1", "h3"])
    }

    @Test func imagePreviewRefreshPreservesSelectionOverrides() throws {
        let imageURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Data("image".utf8).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let service = try seededService(imagePath: imageURL.path)
        let viewModel = StudyPlanViewModel(audiobookID: "book", bookTitle: "Study Book", db: service.writer)
        viewModel.load()
        let firstCandidate = try #require(viewModel.candidates.first)
        viewModel.toggleCandidate(firstCandidate)

        viewModel.includeImages = true
        viewModel.refreshPreviewForImageInclusionChange()

        #expect(viewModel.candidates.map(\.kind) == [.chapter, .image, .chapter, .chapter])
        #expect(!viewModel.selectedCandidateIDs.contains(firstCandidate.id))
        #expect(viewModel.selectedCandidateIDs.contains("image-img1"))
    }

    @Test func existingPlanLoadsManagementStateAndSavesSettings() throws {
        let service = try seededService()
        let dao = StudyPlanDAO(db: service.writer)
        let original = try dao.createPlan(makeCreationRequest())
        let viewModel = StudyPlanViewModel(audiobookID: "book", bookTitle: "Study Book", db: service.writer)

        viewModel.load()
        viewModel.cadenceUnit = .week
        viewModel.newChapterLimit = 3
        viewModel.includeImages = true
        viewModel.queueMode = .mixed
        viewModel.isPaused = true
        let didSave = viewModel.save(now: Self.testDate.addingTimeInterval(60))

        let updated = try #require(try dao.plan(for: "book"))
        #expect(didSave)
        #expect(viewModel.existingPlan?.id == original.plan.id)
        #expect(viewModel.candidates.isEmpty)
        #expect(viewModel.canEditImageInclusion)
        #expect(updated.cadenceUnit == StudyPlanCadenceUnit.week.rawValue)
        #expect(updated.newChapterLimit == 3)
        #expect(updated.includeImages)
        #expect(viewModel.includeImages)
        #expect(updated.queueModeDefault == StudyPlanQueueMode.mixed.rawValue)
        #expect(updated.isPaused)
    }

    @Test func existingPlanCanAddMissingImageItemsWhenEnabled() throws {
        let imageURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Data("image".utf8).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let service = try seededService(imagePath: imageURL.path)
        let dao = StudyPlanDAO(db: service.writer)
        _ = try dao.createPlan(makeCreationRequest())
        let viewModel = StudyPlanViewModel(audiobookID: "book", bookTitle: "Study Book", db: service.writer)

        viewModel.load()
        viewModel.includeImages = true
        let didSave = viewModel.save(now: Self.testDate.addingTimeInterval(60))

        let updated = try #require(try dao.plan(for: "book"))
        let itemSources = try studyPlanItemSourceBlockIDs(in: service)
        let cardTypes = try flashcardTypes(in: service)
        #expect(didSave)
        #expect(updated.includeImages)
        #expect(itemSources == ["h1", "img1"])
        #expect(cardTypes == [StudyFlashcardType.listeningAssignment, StudyFlashcardType.imageAssignment])
    }

    @Test func existingPlanCanDisableImageItemsWhenTurnedOff() throws {
        let imageURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Data("image".utf8).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let service = try seededService(imagePath: imageURL.path)
        let dao = StudyPlanDAO(db: service.writer)
        let setupViewModel = StudyPlanViewModel(audiobookID: "book", bookTitle: "Study Book", db: service.writer)
        setupViewModel.load()
        setupViewModel.includeImages = true
        setupViewModel.refreshPreviewForImageInclusionChange()
        #expect(setupViewModel.save(now: Self.testDate))

        let viewModel = StudyPlanViewModel(audiobookID: "book", bookTitle: "Study Book", db: service.writer)
        viewModel.load()
        viewModel.includeImages = false
        let didSave = viewModel.save(now: Self.testDate.addingTimeInterval(60))

        let updated = try #require(try dao.plan(for: "book"))
        #expect(didSave)
        #expect(!updated.includeImages)
        #expect(try imageItemEnabledStates(in: service) == [false])
        #expect(try imageCardEnabledStates(in: service) == [false])
    }

    @Test func savePostsStudyPlanDidChangeNotification() throws {
        let service = try seededService()
        let viewModel = StudyPlanViewModel(audiobookID: "book", bookTitle: "Study Book", db: service.writer)
        var postCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .studyPlanDidChange,
            object: nil,
            queue: nil
        ) { _ in
            postCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        viewModel.load()
        let didSave = viewModel.save(now: Self.testDate)

        #expect(didSave)
        #expect(postCount == 1)
    }

    @Test func bookTitleResolverUsesStoredAudiobookTitle() throws {
        let service = try DatabaseService(inMemory: ())
        let folderURL = URL(fileURLWithPath: "/tmp/Folder Title")
        let audiobookID = folderURL.absoluteString
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES (?, 'Database Title', 3600, ?)
                    """,
                arguments: [audiobookID, Self.testDate.ISO8601Format()]
            )
        }

        let title = StudyPlanBookTitleResolver.resolve(
            audiobookID: audiobookID,
            folderURL: folderURL,
            db: service.writer,
            currentTitle: "Current Track Title"
        )

        #expect(title == "Database Title")
    }

    @Test func bookTitleResolverFallsBackToFolderBeforeCurrentTitle() {
        let title = StudyPlanBookTitleResolver.resolve(
            storedTitle: nil,
            folderTitle: "Folder Title",
            currentTitle: "Current Track Title"
        )

        #expect(title == "Folder Title")
    }

    @Test func bookTitleResolverUsesCurrentTitleOnlyAfterEmptyStoredAndFolderTitles() {
        let title = StudyPlanBookTitleResolver.resolve(
            storedTitle: " ",
            folderTitle: "\n",
            currentTitle: "Current Book Title"
        )

        #expect(title == "Current Book Title")
    }

    private static let testDate = Date(timeIntervalSince1970: 1_780_000_000)

    private func seededService(imagePath: String? = nil) throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Study Book', 3600, ?)
                    """,
                arguments: [Self.testDate.ISO8601Format()]
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                    ) VALUES
                    ('h1', 'book', 'ch1.xhtml', 0, 0, 0, 'heading', 'Chapter 1', NULL, 0, 0, 0, ?),
                    ('h2', 'book', 'ch2.xhtml', 1, 0, 2, 'heading', 'Chapter 2', NULL, 1, 0, 0, ?),
                    ('h3', 'book', 'ch3.xhtml', 2, 0, 3, 'heading', 'Chapter 3', NULL, 2, 0, 0, ?)
                    """,
                arguments: [
                    Self.testDate.ISO8601Format(),
                    Self.testDate.ISO8601Format(),
                    Self.testDate.ISO8601Format(),
                ]
            )

            if let imagePath {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block (
                            id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                            block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                        ) VALUES
                        ('img1', 'book', 'ch1.xhtml', 0, 1, 1, 'image', NULL, ?, 0, 0, 0, ?)
                        """,
                    arguments: [imagePath, Self.testDate.ISO8601Format()]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                        granularity_level, playlist_position, is_enabled, epub_block_id
                    ) VALUES
                    ('t-h1', 'book', 'textSegment', 'Chapter 1', 0, 100, 1, 0, 1, 'h1'),
                    ('t-h2', 'book', 'textSegment', 'Chapter 2', 100, 200, 1, 100, 1, 'h2'),
                    ('t-h3', 'book', 'textSegment', 'Chapter 3', 200, 300, 1, 200, 1, 'h3')
                    """
            )
            if imagePath != nil {
                try db.execute(
                    sql: """
                        INSERT INTO timeline_item (
                            id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                            granularity_level, playlist_position, is_enabled, epub_block_id
                        ) VALUES
                        ('t-img1', 'book', 'imageAsset', 'Image', 20, NULL, 1, 20, 1, 'img1')
                        """
                )
            }
        }
        return service
    }

    private func flashcardSourceBlockIDs(in service: DatabaseService) throws -> [String] {
        try service.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT source_block_id
                    FROM flashcard
                    ORDER BY media_timestamp, source_block_id
                    """
            )
            .map { row in row["source_block_id"] as String }
        }
    }

    private func studyPlanItemSourceBlockIDs(in service: DatabaseService) throws -> [String] {
        try service.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT source_block_id
                    FROM study_plan_item
                    ORDER BY ordinal, source_block_id
                    """
            )
            .map { row in row["source_block_id"] as String }
        }
    }

    private func flashcardTypes(in service: DatabaseService) throws -> [String] {
        try service.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT card_type
                    FROM flashcard
                    ORDER BY media_timestamp, source_block_id
                    """
            )
            .map { row in row["card_type"] as String }
        }
    }

    private func imageItemEnabledStates(in service: DatabaseService) throws -> [Bool] {
        try service.read { db in
            try StudyPlanItem
                .filter(Column("kind") == StudyPlanItemKind.image.rawValue)
                .order(Column("ordinal"), Column("source_block_id"))
                .fetchAll(db)
                .map(\.isEnabled)
        }
    }

    private func imageCardEnabledStates(in service: DatabaseService) throws -> [Bool] {
        try service.read { db in
            try Flashcard
                .filter(Column("card_type") == StudyFlashcardType.imageAssignment)
                .order(Column("media_timestamp"), Column("source_block_id"))
                .fetchAll(db)
                .map(\.isEnabled)
        }
    }

    private func makeCreationRequest() -> StudyPlanCreationRequest {
        StudyPlanCreationRequest(
            audiobookID: "book",
            bookTitle: "Study Book",
            cadenceUnit: .day,
            newChapterLimit: 1,
            includeImages: false,
            queueMode: .bookByBook,
            catchUpPolicy: .gentle,
            startDate: Self.testDate,
            candidates: [
                StudyPlanCandidate(
                    id: "chapter-h1",
                    kind: .chapter,
                    sourceBlockID: "h1",
                    chapterIndex: 0,
                    ordinal: 0,
                    title: "Chapter 1",
                    defaultIncluded: true,
                    imagePath: nil,
                    mediaTimestamp: 0,
                    endTimestamp: 100,
                    playlistPosition: nil
                ),
            ],
            now: Self.testDate
        )
    }
}
