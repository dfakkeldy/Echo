// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Proves a successfully imported portable (formatVersion 2) `manualOnly`
/// flashcard flows through Echo's EXISTING due-card / session / FSRS / sync
/// path unmodified, while playback triggering correctly excludes it:
///
/// 1. It appears in `FlashcardDAO.allDueCards`.
/// 2. It appears in `StudyQueueBuilder.build`'s entries.
/// 3. `SourceAnchoredCardTriggerResolver` never auto-triggers it during
///    playback (`manualOnly` is never eligible, regardless of block).
/// 4. Grading it through `FlashcardDAO.grade` advances FSRS scheduling
///    exactly like any other card.
///
/// It also asserts the persisted flashcard's deck id, selected LOCAL
/// audiobook id (never the `echo-portable:` sentinel), enabled state,
/// trigger timing, and resolved EPUB source block id; and the synchronized
/// timeline row's selected LOCAL audiobook id and EPUB block id.
/// `TimelineItem` has no `deck_id` or `trigger_timing` column, so it cannot
/// duplicate those fields — this is asserted structurally by only reading
/// the columns it does have.
///
/// Portability means the same deck file can be imported against matching
/// local copies on multiple devices — this test proves that already-local,
/// already-imported card behaves like any other local card afterward. It
/// does not add, exercise, or require any automatic deck-sync format.
@MainActor
@Suite struct PortableDeckStudyFlowTests {

    // MARK: - Fixture helpers (mirrors PortableDeckPersistenceTests)

    private func seedSelectedAudiobook(
        _ writer: DatabaseWriter, id: String, blocks: [EPubBlockRecord]
    ) throws {
        try writer.write { db in
            var audiobook = AudiobookRecord(
                id: id,
                title: id,
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
            )
            try audiobook.insert(db)
            for var block in blocks {
                try block.insert(db)
            }
        }
    }

    private func makeBlock(
        suffix: String,
        audiobookID: String,
        sequenceIndex: Int,
        text: String = "Block text"
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-\(audiobookID)-\(suffix)",
            audiobookID: audiobookID,
            spineHref: "Text/chapter.xhtml",
            spineIndex: sequenceIndex,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func makePortableCard(
        sourceAnchor: String?, frontText: String = "Question"
    ) -> FlashcardDeckImport.ImportedCard {
        FlashcardDeckImport.ImportedCard(
            frontText: frontText,
            backText: "Answer",
            startTime: nil,
            endTime: nil,
            triggerTiming: FlashcardTriggerTiming.manualOnly.rawValue,
            sourceAnchor: sourceAnchor,
            imageAnchor: nil,
            imageFile: nil
        )
    }

    private func makePortableDeckDocument(
        deckID: String,
        deckName: String,
        targetMediaID: String = "echo-portable:test-slug:core",
        sourceSignature: EchoSourceSignature,
        cards: [FlashcardDeckImport.ImportedCard]
    ) -> FlashcardDeckImport {
        FlashcardDeckImport(
            formatVersion: 2,
            deckID: deckID,
            deckName: deckName,
            targetBinding: "selectedBook",
            targetMediaID: targetMediaID,
            sourceSignature: sourceSignature,
            cards: cards
        )
    }

    private func writeDeckFile(_ deck: FlashcardDeckImport) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-deck-study-flow_\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(deck)
        try data.write(to: url)
        return url
    }

    // MARK: - The proof

    @Test
    func importedManualOnlyCardFlowsThroughDueSessionFSRSAndSyncWhilePlaybackExcludesIt() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let localAudiobookID = "local-book-selected"
        let block = makeBlock(suffix: "s0-b0", audiobookID: localAudiobookID, sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: localAudiobookID, blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.test.study-flow-deck"

        let deck = makePortableDeckDocument(
            deckID: deckID, deckName: "Study Flow Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let url = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DeckImportService().importDeckVNext(
            from: url, targetAudiobookID: localAudiobookID, db: writer)
        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 1)

        let now = Date()

        // Behavior 1: the imported card is included in the existing
        // due-card path exactly like any other due card.
        let due = try FlashcardDAO(db: writer).allDueCards(now: now)
        #expect(due.map(\.deckID) == [deckID])

        // Behavior 2: the imported card is included in the existing
        // session/queue-building path.
        let queue = try StudyQueueBuilder(db: writer).build(now: now)
        #expect(queue.entries.compactMap(\.flashcard.deckID).contains(deckID))

        // Behavior 3: playback triggering excludes it. `manualOnly` cards
        // are never eligible for auto-trigger, regardless of which block is
        // active — proven here with the active block set to the card's own
        // resolved source block, the case most likely to (wrongly) trigger.
        let triggerResult = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: nil,
            activeBlockID: due[0].sourceBlockID,
            cards: due,
            state: .init()
        )
        #expect(triggerResult.cardsToTrigger.isEmpty)

        // Persisted-flashcard invariants: deck id, selected LOCAL audiobook
        // id (never the `echo-portable:` sentinel from the deck document),
        // enabled state, trigger timing, and the resolved EPUB source block
        // id.
        #expect(due[0].deckID == deckID)
        #expect(due[0].audiobookID == localAudiobookID)
        #expect(due[0].isEnabled == true)
        #expect(due[0].triggerTiming == .manualOnly)
        #expect(due[0].sourceBlockID == block.id)

        // Synchronized timeline row: selected LOCAL audiobook id and EPUB
        // block id. `TimelineItem` has no `deck_id` or `trigger_timing`
        // column — those fields are never duplicated onto the timeline row,
        // only read from the two columns that actually exist.
        let timelineRow = try writer.read { database in
            try TimelineItem.fetchOne(
                database,
                sql: """
                    SELECT * FROM timeline_item
                    WHERE source_table = 'flashcard' AND source_rowid = ?
                    """,
                arguments: [due[0].id]
            )
        }
        #expect(timelineRow?.audiobookID == localAudiobookID)
        #expect(timelineRow?.epubBlockID == block.id)

        // Behavior 4: FSRS grading advances scheduling exactly like any
        // other card.
        try FlashcardDAO(db: writer).grade(
            cardID: due[0].id,
            grade: ReviewGrade.good.rawValue,
            now: now
        )
        let reviewed = try writer.read { database in
            try Flashcard.fetchOne(database, key: due[0].id)
        }
        #expect(reviewed?.repetitions == 1)
        #expect(reviewed?.nextReviewDate != nil)
    }
}
