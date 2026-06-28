// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyDeckSourceBuilderTests {
    @Test func wholeBookFiltersEligibleTextBlocksInReadingOrder() throws {
        let service = try seededService()
        let builder = StudyDeckSourceBuilder(db: service.writer)

        let sources = try builder.sources(audiobookID: "book", selection: .wholeBook)

        #expect(sources.map(\.sourceBlockID) == ["heading-1", "para-1", "sentence-1", "para-2"])
        #expect(sources.map(\.blockKind) == ["heading", "paragraph", "sentence", "paragraph"])
        #expect(sources.map(\.sequenceIndex) == [1, 3, 4, 8])
        #expect(sources.allSatisfy { $0.audiobookID == "book" })
    }

    @Test func explicitSelectionKeepsOnlyMatchingEligibleBlocksForBook() throws {
        let service = try seededService()
        let builder = StudyDeckSourceBuilder(db: service.writer)

        let sources = try builder.sources(
            audiobookID: "book",
            selection: .explicitSourceBlockIDs([
                "para-2",
                "front",
                "hidden",
                "image",
                "other-book",
                "missing",
                "para-1",
            ])
        )

        #expect(sources.map(\.sourceBlockID) == ["para-1", "para-2"])
    }

    @Test func currentSelectionReturnsOneEligibleMatchingBlock() throws {
        let service = try seededService()
        let builder = StudyDeckSourceBuilder(db: service.writer)

        let selected = try builder.sources(
            audiobookID: "book",
            selection: .currentSourceBlockID("sentence-1")
        )
        let hidden = try builder.sources(
            audiobookID: "book",
            selection: .currentSourceBlockID("hidden")
        )

        #expect(selected.map(\.sourceBlockID) == ["sentence-1"])
        #expect(hidden.isEmpty)
    }

    @Test func chapterSelectionReturnsOnlyThatChapter() throws {
        let service = try seededService()
        let builder = StudyDeckSourceBuilder(db: service.writer)

        let sources = try builder.sources(audiobookID: "book", selection: .chapter(1))

        #expect(sources.map(\.sourceBlockID) == ["sentence-1", "para-2"])
        #expect(sources.map(\.chapterIndex) == [1, 1])
    }

    @Test func trimsTextAndPreservesSourceBlockID() throws {
        let service = try seededService()
        let builder = StudyDeckSourceBuilder(db: service.writer)

        let sources = try builder.sources(
            audiobookID: "book",
            selection: .currentSourceBlockID("para-1")
        )
        let source = try #require(sources.first)

        #expect(source.id == "para-1")
        #expect(source.sourceBlockID == "para-1")
        #expect(source.text == "First short idea.")
        #expect(source.spineIndex == 1)
        #expect(source.blockIndex == 2)
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES
                    ('book', 'Synthetic Study Book', 300, '2026-06-01T00:00:00Z'),
                    ('other', 'Other Synthetic Book', 300, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter,
                        created_at
                    ) VALUES
                    ('para-2', 'book', 'ch2.xhtml', 2, 1, 8, 'paragraph', 'Second short idea.', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    ('front', 'book', 'front.xhtml', 0, 0, 0, 'heading', 'Front sample', NULL, -1, 0, 1, '2026-06-01T00:00:00Z'),
                    ('heading-1', 'book', 'ch1.xhtml', 1, 0, 1, 'heading', 'Chapter Sample', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('image', 'book', 'ch1.xhtml', 1, 1, 2, 'image', NULL, '/tmp/synthetic.png', 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('para-1', 'book', 'ch1.xhtml', 1, 2, 3, 'paragraph', '  First short idea.  ', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('sentence-1', 'book', 'ch2.xhtml', 2, 0, 4, 'sentence', 'A concise sentence.', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    ('blank', 'book', 'ch2.xhtml', 2, 2, 5, 'paragraph', '   ', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    ('hidden', 'book', 'ch2.xhtml', 2, 3, 6, 'paragraph', 'Hidden sample', NULL, 1, 1, 0, '2026-06-01T00:00:00Z'),
                    ('unknown-kind', 'book', 'ch2.xhtml', 2, 4, 7, 'aside', 'Aside sample', NULL, 1, 0, 0, '2026-06-01T00:00:00Z'),
                    ('other-book', 'other', 'ch1.xhtml', 1, 0, 1, 'paragraph', 'Other book sample', NULL, 0, 0, 0, '2026-06-01T00:00:00Z')
                    """
            )
        }
        return service
    }
}
