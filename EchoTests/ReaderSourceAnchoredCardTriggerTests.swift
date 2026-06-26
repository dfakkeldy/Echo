// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite
struct ReaderSourceAnchoredCardTriggerTests {
    @Test
    func updateActiveBlockQueuesBeginningCardOnEntry() throws {
        let service = try DatabaseService(inMemory: ())
        try seedAudiobook(service)
        try seedBlockAndTimeline(service, blockID: "b1", start: 0, end: 5)
        try FlashcardDAO(db: service.writer).insert(
            makeCard(id: "card-1", sourceBlockID: "b1", triggerTiming: .beginning))

        let vm = ReaderFeedViewModel(audiobookID: "book", db: service.writer)
        vm.reload()
        vm.updateActiveBlock(time: 1, currentTrackChapterIndices: nil, isPlaying: true)

        #expect(vm.pendingSourceAnchoredCardIDs == ["card-1"])
        #expect(vm.consumePendingSourceAnchoredCardIDs() == ["card-1"])
        #expect(vm.pendingSourceAnchoredCardIDs.isEmpty)
    }

    @Test
    func updateActiveBlockQueuesEndCardOnExit() throws {
        let service = try DatabaseService(inMemory: ())
        try seedAudiobook(service)
        try seedBlockAndTimeline(service, blockID: "b1", start: 0, end: 5)
        try seedBlockAndTimeline(service, blockID: "b2", start: 5, end: 10, blockIndex: 1, sequenceIndex: 1)
        try FlashcardDAO(db: service.writer).insert(
            makeCard(id: "card-1", sourceBlockID: "b1", triggerTiming: .end))

        let vm = ReaderFeedViewModel(audiobookID: "book", db: service.writer)
        vm.reload()
        vm.updateActiveBlock(time: 1, currentTrackChapterIndices: nil, isPlaying: true)
        vm.updateActiveBlock(time: 6, currentTrackChapterIndices: nil, isPlaying: true)

        #expect(vm.pendingSourceAnchoredCardIDs == ["card-1"])
    }

    @Test
    func pausedPlaybackDoesNotQueueCards() throws {
        let service = try DatabaseService(inMemory: ())
        try seedAudiobook(service)
        try seedBlockAndTimeline(service, blockID: "b1", start: 0, end: 5)
        try FlashcardDAO(db: service.writer).insert(
            makeCard(id: "card-1", sourceBlockID: "b1", triggerTiming: .beginning))

        let vm = ReaderFeedViewModel(audiobookID: "book", db: service.writer)
        vm.reload()
        vm.updateActiveBlock(time: 1, currentTrackChapterIndices: nil, isPlaying: false)

        #expect(vm.pendingSourceAnchoredCardIDs.isEmpty)
    }

    @Test
    func updateActiveBlockRecordsTriggerSummary() throws {
        let service = try DatabaseService(inMemory: ())
        try seedAudiobook(service)
        try seedBlockAndTimeline(service, blockID: "b1", start: 0, end: 5)
        try FlashcardDAO(db: service.writer).insert(
            makeCard(id: "card-1", sourceBlockID: "b1", triggerTiming: .beginning))

        let vm = ReaderFeedViewModel(audiobookID: "book", db: service.writer)
        vm.reload()
        vm.updateActiveBlock(time: 1, currentTrackChapterIndices: nil, isPlaying: true)

        #expect(vm.lastSourceAnchoredCardTriggerSummary?.activeBlockID == "b1")
        #expect(vm.lastSourceAnchoredCardTriggerSummary?.candidateCount == 1)
        #expect(vm.lastSourceAnchoredCardTriggerSummary?.triggeredCount == 1)
        #expect(vm.lastSourceAnchoredCardTriggerSummary?.suppressedCount == 0)
    }

    private func seedAudiobook(_ service: DatabaseService) throws {
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Book', 100, '2026-06-01T00:00:00Z')
                    """)
        }
    }

    private func seedBlockAndTimeline(
        _ service: DatabaseService,
        blockID: String,
        start: TimeInterval,
        end: TimeInterval,
        blockIndex: Int = 0,
        sequenceIndex: Int = 0
    ) throws {
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, chapter_index, is_hidden)
                    VALUES (?, 'book', 'Text/chapter.xhtml', 0, ?, ?, 'paragraph', 0, 0)
                    """,
                arguments: [blockID, blockIndex, sequenceIndex])

            var item = TimelineItem(
                id: "ti-\(blockID)",
                audiobookID: "book",
                itemType: .textSegment,
                title: blockID,
                subtitle: nil,
                textPayload: nil,
                imagePath: nil,
                audioStartTime: start,
                audioEndTime: end,
                epubSequenceIndex: nil,
                granularityLevel: .paragraph,
                playlistPosition: nil,
                isEnabled: true,
                sourceTable: nil,
                sourceRowid: nil,
                metadataJSON: nil,
                pdfViewStateJSON: nil,
                epubBlockID: blockID,
                segmentKey: nil,
                timestampSource: nil,
                alignmentStatus: nil,
                alignmentConfidence: nil,
                createdAt: nil,
                modifiedAt: nil
            )
            try item.insert(db)
        }
    }

    private func makeCard(
        id: String,
        sourceBlockID: String,
        triggerTiming: FlashcardTriggerTiming
    ) -> Flashcard {
        let stamp = "2026-06-01T00:00:00Z"
        return Flashcard(
            id: id,
            audiobookID: "book",
            frontText: "Front",
            backText: "Back",
            mediaTimestamp: 0,
            endTimestamp: nil,
            triggerTiming: triggerTiming,
            nextReviewDate: nil,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: nil,
            tags: nil,
            mediaJSON: nil,
            sourceBlockID: sourceBlockID,
            playlistPosition: nil,
            createdAt: stamp,
            modifiedAt: stamp,
            stability: nil,
            difficulty: nil,
            cardType: "normal",
            clozeIndex: nil
        )
    }
}
