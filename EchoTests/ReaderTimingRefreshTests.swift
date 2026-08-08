// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ReaderTimingRefreshTests {
    @Test func reloadPicksUpWordsInsertedAfterInitialReaderLoad() throws {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 60)"
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                        (id, audiobook_id, spine_href, spine_index, block_index,
                         sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES
                        ('b1', 'book', 'chapter.xhtml', 0, 0, 0,
                         'paragraph', 'One tool remains', 0, 0)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                        (id, audiobook_id, item_type, title, audio_start_time,
                         audio_end_time, epub_block_id, alignment_status)
                    VALUES
                        ('t1', 'book', 'paragraph', 'Paragraph', 0, 4, 'b1', 'auto')
                    """
            )
        }

        let viewModel = ReaderFeedViewModel(audiobookID: "book", db: service.writer)
        viewModel.reload()
        viewModel.updateActiveBlock(time: 1.25, currentTrackChapterIndices: nil)
        #expect(viewModel.activeBlockID == "b1")
        #expect(viewModel.activeWord == nil)

        try WordTimingDAO(db: service.writer).insert([
            WordTimingRecord(
                audiobookID: "book",
                epubBlockID: "b1",
                wordIndex: 0,
                word: "One",
                audioStartTime: 1,
                audioEndTime: 1.5,
                confidence: 1,
                source: "sidecar"
            )
        ])

        viewModel.reload()
        viewModel.updateActiveBlock(time: 1.25, currentTrackChapterIndices: nil)
        #expect(viewModel.activeWord?.blockID == "b1")
        #expect(viewModel.activeWord?.index == 0)
    }
}
