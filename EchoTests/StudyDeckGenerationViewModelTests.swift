// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Echo

@MainActor
@Suite struct StudyDeckGenerationViewModelTests {

    // MARK: - Injected-generator test

    private struct StubGenerator: StudyDeckGenerating {
        let cards: [GeneratedStudyDeckCardDraft]
        func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            GeneratedStudyDeckDraft(
                cards: cards, validSourceBlockIDs: Set(cards.map(\.sourceBlockID)))
        }
    }

    /// Reports progress through an injected closure, then returns its cards. Lets the VM
    /// test drive `viewModel.progress` without a network round-trip.
    private struct ProgressGenerator: StudyDeckGenerating {
        let cards: [GeneratedStudyDeckCardDraft]
        let report: @Sendable (Int, Int) -> Void
        func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            report(1, 2)
            report(2, 2)
            return GeneratedStudyDeckDraft(
                cards: cards, validSourceBlockIDs: Set(cards.map(\.sourceBlockID)))
        }
    }

    /// Blocks until cancelled, then returns an empty draft. Lets the VM test assert
    /// `cancelLoad()` actually unblocks an in-flight load.
    private struct CancellableGenerator: StudyDeckGenerating {
        let started: @Sendable () -> Void
        func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            started()
            while !Task.isCancelled {
                await Task.yield()
            }
            return GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: [])
        }
    }

    /// Test-only weak holder so the @Sendable progress closure can reach the @MainActor VM
    /// (constructed after the closure) and bridge progress onto it, mirroring the real
    /// `{ [weak self] … Task { @MainActor in self?.progress = … } }` call-site pattern.
    private final class WeakVMBox: @unchecked Sendable {
        weak var vm: StudyDeckGenerationViewModel?
        /// Progress values read back from the VM after each bridged write (MainActor-only access).
        var observed: [(Int, Int)] = []
    }

    @Test func loadReportsGeneratorProgress() async throws {
        let service = try seededService()
        let captured = Mutex<[(Int, Int)]>([])
        let card = GeneratedStudyDeckCardDraft(
            id: "stub-card", sourceBlockID: "block-1", frontText: "Q", backText: "A")
        let box = WeakVMBox()
        // The generator reports progress; the bridge hops to the MainActor (mirroring the real
        // `{ [weak self] … Task { @MainActor in self?.progress = … } }` call site), writes the VM,
        // then reads it back into the box so we can assert the VM was driven without racing
        // load()'s reset.
        let generator = ProgressGenerator(cards: [card]) { done, total in
            captured.withLock { $0.append((done, total)) }
            Task { @MainActor in
                box.vm?.progress = (done, total)
                if let p = box.vm?.progress {
                    box.observed.append((p.done, p.total))
                }
            }
        }
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer,
            generator: generator
        )
        box.vm = viewModel

        await viewModel.load()
        // Drain any trailing MainActor progress writes scheduled by the bridge.
        for _ in 0..<8 { await Task.yield() }

        #expect(captured.withLock { $0.map(\.0) } == [1, 2])
        // The bridge drove viewModel.progress to the reported values at least once.
        await MainActor.run { #expect(box.observed.contains { $0 == (2, 2) }) }
        #expect(viewModel.cards.map(\.id) == ["stub-card"])
    }

    @Test func progressResetsToNilWhenLoadFinishes() async throws {
        let service = try seededService()
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer
        )
        // Stale progress from a prior run must be cleared by the next completed load.
        viewModel.progress = (1, 3)

        await viewModel.load()

        #expect(viewModel.progress == nil)
        #expect(!viewModel.isLoading)
    }

    @Test func cancelLoadCancelsInFlightLoad() async throws {
        let service = try seededService()
        let didStart = Mutex(false)
        let generator = CancellableGenerator { didStart.withLock { $0 = true } }
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer,
            generator: generator
        )

        let loadTask = Task { await viewModel.load() }
        // Wait until the generator is running, then cancel.
        while !(didStart.withLock { $0 }) {
            await Task.yield()
        }
        viewModel.cancelLoad()
        await loadTask.value

        #expect(!viewModel.isLoading)
    }

    @Test func loadUsesInjectedGenerator() async throws {
        let service = try seededService()
        let card = GeneratedStudyDeckCardDraft(
            id: "stub-card",
            sourceBlockID: "block-1",
            frontText: "Q",
            backText: "A"
        )
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer,
            generator: StubGenerator(cards: [card])
        )
        await viewModel.load()
        #expect(viewModel.cards.map(\.id) == ["stub-card"])
        #expect(!viewModel.isLoading)
        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Existing tests (load() is now async)

    @Test func loadBuildsFixtureCardsAndSelectsThemByDefault() async throws {
        let service = try seededService()
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer
        )

        await viewModel.load()

        #expect(viewModel.cards.map(\.sourceBlockID) == ["block-1", "block-2"])
        #expect(viewModel.cards.map(\.id) == ["fixture-block-1", "fixture-block-2"])
        #expect(viewModel.selectedCardIDs == Set(viewModel.cards.map(\.id)))
        #expect(viewModel.selectedCardCount == 2)
        #expect(viewModel.canAccept)
        #expect(!viewModel.isLoading)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func toggleCardUpdatesSelectedIDs() async throws {
        let service = try seededService()
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer
        )
        await viewModel.load()
        let card = try #require(viewModel.cards.first)

        viewModel.toggleCard(card)
        #expect(!viewModel.selectedCardIDs.contains(card.id))
        #expect(viewModel.selectedCardCount == 1)

        viewModel.toggleCard(card)
        #expect(viewModel.selectedCardIDs.contains(card.id))
        #expect(viewModel.selectedCardCount == 2)
    }

    @Test func acceptInsertsOnlySelectedCardsAndPostsRefreshNotifications() async throws {
        let service = try seededService()
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer
        )
        let timelineAudiobookIDs = Mutex<[String]>([])
        let studyQueuePostCount = Mutex(0)
        let timelineObserver = NotificationCenter.default.addObserver(
            forName: .timelineItemsIngested,
            object: nil,
            queue: nil
        ) { notification in
            if let audiobookID = notification.userInfo?["audiobookID"] as? String {
                timelineAudiobookIDs.withLock { $0.append(audiobookID) }
            }
        }
        let queueObserver = NotificationCenter.default.addObserver(
            forName: .studyQueueDidChange,
            object: nil,
            queue: nil
        ) { _ in
            studyQueuePostCount.withLock { $0 += 1 }
        }
        defer {
            NotificationCenter.default.removeObserver(timelineObserver)
            NotificationCenter.default.removeObserver(queueObserver)
        }

        await viewModel.load()
        let deselected = try #require(viewModel.cards.last)
        viewModel.toggleCard(deselected)
        let didAccept = viewModel.accept(now: Self.fixedNow)

        #expect(didAccept)
        #expect(viewModel.acceptedCount == 1)
        #expect(!viewModel.isAccepting)
        #expect(viewModel.errorMessage == nil)
        #expect(try persistedCardSourceBlockIDs(in: service) == ["block-1"])
        #expect(timelineAudiobookIDs.withLock { $0 } == ["book"])
        #expect(studyQueuePostCount.withLock { $0 } == 1)
    }

    @Test func loadHandlesNoEligibleBlocksAsEmptyDraft() async throws {
        let service = try seededService(includeEligibleBlocks: false)
        let viewModel = StudyDeckGenerationViewModel(
            audiobookID: "book",
            bookTitle: "Synthetic Study Book",
            db: service.writer
        )

        await viewModel.load()

        #expect(viewModel.cards.isEmpty)
        #expect(viewModel.selectedCardIDs.isEmpty)
        #expect(!viewModel.canAccept)
        #expect(!viewModel.isLoading)
        #expect(viewModel.errorMessage == nil)
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_780_100_000)

    private func seededService(includeEligibleBlocks: Bool = true) throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Synthetic Study Book', 600, '2026-06-01T00:00:00Z')
                    """
            )
            if includeEligibleBlocks {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block (
                            id, audiobook_id, spine_href, spine_index, block_index,
                            sequence_index, block_kind, text, image_path, chapter_index,
                            is_hidden, is_front_matter, created_at
                        ) VALUES
                        ('block-1', 'book', 'ch1.xhtml', 0, 0, 0, 'paragraph',
                         'Synthetic retrieval practice strengthens recall.', NULL, 0, 0, 0,
                         '2026-06-01T00:00:00Z'),
                        ('image-1', 'book', 'ch1.xhtml', 0, 1, 1, 'image',
                         NULL, '/tmp/synthetic.png', 0, 0, 0, '2026-06-01T00:00:00Z'),
                        ('block-2', 'book', 'ch1.xhtml', 0, 2, 2, 'sentence',
                         'Compact review links related ideas.', NULL, 0, 0, 0,
                         '2026-06-01T00:00:00Z'),
                        ('hidden-1', 'book', 'ch1.xhtml', 0, 3, 3, 'paragraph',
                         'Hidden synthetic text.', NULL, 0, 1, 0, '2026-06-01T00:00:00Z'),
                        ('front-1', 'book', 'front.xhtml', 0, 4, 4, 'heading',
                         'Front synthetic text.', NULL, -1, 0, 1, '2026-06-01T00:00:00Z')
                        """
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block (
                            id, audiobook_id, spine_href, spine_index, block_index,
                            sequence_index, block_kind, text, image_path, chapter_index,
                            is_hidden, is_front_matter, created_at
                        ) VALUES
                        ('image-1', 'book', 'ch1.xhtml', 0, 0, 0, 'image',
                         NULL, '/tmp/synthetic.png', 0, 0, 0, '2026-06-01T00:00:00Z'),
                        ('hidden-1', 'book', 'ch1.xhtml', 0, 1, 1, 'paragraph',
                         'Hidden synthetic text.', NULL, 0, 1, 0, '2026-06-01T00:00:00Z'),
                        ('front-1', 'book', 'front.xhtml', 0, 2, 2, 'heading',
                         'Front synthetic text.', NULL, -1, 0, 1, '2026-06-01T00:00:00Z')
                        """
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time,
                        audio_end_time, granularity_level, playlist_position, is_enabled,
                        source_table, source_rowid, epub_block_id
                    ) VALUES
                    ('epub-block-1', 'book', 'textSegment', 'Block 1', 10, 20, 1, 10, 1,
                     'epub_block', 'block-1', 'block-1'),
                    ('epub-block-2', 'book', 'textSegment', 'Block 2', 30, 40, 1, 30, 1,
                     'epub_block', 'block-2', 'block-2')
                    """
            )
        }
        return service
    }

    private func persistedCardSourceBlockIDs(in service: DatabaseService) throws -> [String] {
        try service.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT source_block_id
                    FROM flashcard
                    ORDER BY source_block_id
                    """
            )
            .map { row in row["source_block_id"] as String }
        }
    }
}
