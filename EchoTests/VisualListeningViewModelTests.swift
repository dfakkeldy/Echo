// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct VisualListeningViewModelTests {
    @Test func reloadLoadsOnlyRequestedAudiobook() async throws {
        let db = try makeDatabase()
        try insertFixture(
            db,
            audiobookID: "book-1",
            imageID: "book-1-image",
            textID: "book-1-text",
            imagePath: "book-1.jpg",
            text: "Book one subtitle.",
            start: 0,
            end: 10,
            word: "Book"
        )
        try insertFixture(
            db,
            audiobookID: "book-2",
            imageID: "book-2-image",
            textID: "book-2-text",
            imagePath: "book-2.jpg",
            text: "Book two subtitle.",
            start: 0,
            end: 10,
            word: "Other"
        )

        let viewModel = VisualListeningViewModel(audiobookID: "book-1", db: db.writer)
        await viewModel.reload()
        viewModel.update(
            time: 0.5,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil
        )

        #expect(viewModel.hasVisualListeningContent)
        #expect(viewModel.snapshot.imageCue?.blockID == "book-1-image")
        #expect(viewModel.snapshot.subtitleCue?.text == "Book one subtitle.")
        #expect(viewModel.snapshot.subtitleCue?.activeWordIndex == 0)
    }

    @Test func contentAvailabilityRequiresImageAndSubtitleTimeline() async throws {
        let imageOnlyDB = try makeDatabase()
        try insertBlock(
            imageOnlyDB,
            block("image", audiobookID: "book", sequence: 0, kind: .image, imagePath: "image.jpg")
        )

        let textOnlyDB = try makeDatabase()
        try insertBlock(
            textOnlyDB,
            block("text", audiobookID: "book", sequence: 0, kind: .paragraph, text: "Only text")
        )
        try insertTimeline(textOnlyDB, audiobookID: "book", id: "text-row", blockID: "text", start: 0, end: 5)

        let completeDB = try makeDatabase()
        try insertFixture(
            completeDB,
            audiobookID: "book",
            imageID: "image",
            textID: "text",
            imagePath: "image.jpg",
            text: "Ready",
            start: 0,
            end: 5,
            word: "Ready"
        )

        let imageOnly = VisualListeningViewModel(audiobookID: "book", db: imageOnlyDB.writer)
        let textOnly = VisualListeningViewModel(audiobookID: "book", db: textOnlyDB.writer)
        let complete = VisualListeningViewModel(audiobookID: "book", db: completeDB.writer)

        await imageOnly.reload()
        await textOnly.reload()
        await complete.reload()

        #expect(!imageOnly.hasVisualListeningContent)
        #expect(!textOnly.hasVisualListeningContent)
        #expect(complete.hasVisualListeningContent)
    }

    @Test func updateRefreshesImageAndSubtitleAsPlaybackMoves() async throws {
        let db = try makeDatabase()
        try insertFixture(
            db,
            audiobookID: "book",
            imageID: "image-1",
            textID: "text-1",
            imagePath: "one.jpg",
            text: "First line.",
            start: 0,
            end: 5,
            word: "First"
        )
        try insertFixture(
            db,
            audiobookID: "book",
            imageID: "image-2",
            textID: "text-2",
            imagePath: "two.jpg",
            text: "Second line.",
            start: 10,
            end: 15,
            word: "Second",
            sequenceBase: 10
        )

        let viewModel = VisualListeningViewModel(audiobookID: "book", db: db.writer)
        viewModel.syncPoint = .begin
        await viewModel.reload()

        viewModel.update(time: 1, currentTrackSegmentKey: nil, currentTrackChapterIndices: nil)
        #expect(viewModel.snapshot.imageCue?.blockID == "image-1")
        #expect(viewModel.snapshot.subtitleCue?.blockID == "text-1")

        viewModel.update(time: 12, currentTrackSegmentKey: nil, currentTrackChapterIndices: nil)
        #expect(viewModel.snapshot.imageCue?.blockID == "image-2")
        #expect(viewModel.snapshot.subtitleCue?.blockID == "text-2")
    }

    @Test func updatePassesTrackScopeIntoResolver() async throws {
        let db = try makeDatabase()
        try insertFixture(
            db,
            audiobookID: "book",
            imageID: "c0-image",
            textID: "c0-text",
            imagePath: "c0.jpg",
            text: "Chapter zero.",
            start: 0,
            end: 10,
            word: "Zero",
            chapter: 0
        )
        try insertFixture(
            db,
            audiobookID: "book",
            imageID: "c1-image",
            textID: "c1-text",
            imagePath: "c1.jpg",
            text: "Chapter one.",
            start: 0,
            end: 10,
            word: "One",
            chapter: 1,
            sequenceBase: 10
        )

        let viewModel = VisualListeningViewModel(audiobookID: "book", db: db.writer)
        await viewModel.reload()
        viewModel.update(time: 2, currentTrackSegmentKey: nil, currentTrackChapterIndices: [1])

        #expect(viewModel.snapshot.imageCue?.blockID == "c1-image")
        #expect(viewModel.snapshot.subtitleCue?.blockID == "c1-text")
    }

    @Test func changingSyncPointRecomputesCurrentSnapshot() async throws {
        let db = try makeDatabase()
        try insertFixture(
            db,
            audiobookID: "book",
            imageID: "image",
            textID: "text",
            imagePath: "figure.jpg",
            text: "Relevant section.",
            start: 10,
            end: 20,
            word: "Relevant"
        )

        let viewModel = VisualListeningViewModel(audiobookID: "book", db: db.writer)
        viewModel.syncPoint = .begin
        await viewModel.reload()
        viewModel.update(time: 6, currentTrackSegmentKey: nil, currentTrackChapterIndices: nil)

        #expect(viewModel.snapshot.imageCue == nil)

        viewModel.syncPoint = .midpoint

        #expect(viewModel.snapshot.imageCue?.blockID == "image")
        #expect(viewModel.snapshot.imageCue?.displayStartTime == 5)
    }

    private func makeDatabase() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 60)")
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'One', 60)")
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-2', 'Two', 60)")
        }
        return db
    }

    private func insertFixture(
        _ db: DatabaseService,
        audiobookID: String,
        imageID: String,
        textID: String,
        imagePath: String,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        word: String,
        chapter: Int = 0,
        sequenceBase: Int = 0
    ) throws {
        try insertBlock(
            db,
            block(
                imageID,
                audiobookID: audiobookID,
                sequence: sequenceBase,
                kind: .image,
                imagePath: imagePath,
                chapter: chapter
            )
        )
        try insertBlock(
            db,
            block(
                textID,
                audiobookID: audiobookID,
                sequence: sequenceBase + 1,
                kind: .paragraph,
                text: text,
                chapter: chapter
            )
        )
        try insertTimeline(
            db,
            audiobookID: audiobookID,
            id: "\(textID)-timeline",
            blockID: textID,
            start: start,
            end: end
        )
        try WordTimingDAO(db: db.writer).insert([
            WordTimingRecord(
                audiobookID: audiobookID,
                epubBlockID: textID,
                wordIndex: 0,
                word: word,
                audioStartTime: start,
                audioEndTime: min(end, start + 1),
                confidence: 0.9,
                source: "test"
            )
        ])
    }

    private func insertBlock(_ db: DatabaseService, _ block: EPubBlockRecord) throws {
        try EPubBlockDAO(db: db.writer).insert(block)
    }

    private func insertTimeline(
        _ db: DatabaseService,
        audiobookID: String,
        id: String,
        blockID: String,
        start: TimeInterval,
        end: TimeInterval,
        segmentKey: String? = nil
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                        (id, audiobook_id, item_type, title, audio_start_time, audio_end_time, epub_block_id, segment_key, alignment_status)
                    VALUES (?, ?, 'textSegment', 'x', ?, ?, ?, ?, 'test')
                    """,
                arguments: [id, audiobookID, start, end, blockID, segmentKey]
            )
        }
    }

    private func block(
        _ id: String,
        audiobookID: String,
        sequence: Int,
        kind: EPubBlockRecord.Kind,
        text: String? = nil,
        imagePath: String? = nil,
        chapter: Int? = 0,
        hidden: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: audiobookID,
            spineHref: "chapter.xhtml",
            spineIndex: chapter ?? 0,
            blockIndex: sequence,
            sequenceIndex: sequence,
            blockKind: kind.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: chapter,
            isHidden: hidden,
            hiddenReason: hidden ? "test" : nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}
