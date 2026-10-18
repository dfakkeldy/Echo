// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyPlanGeneratorTests {
    @Test func previewExcludesFrontMatterAndHiddenHeadings() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in true })

        let preview = try generator.preview(
            audiobookID: "book",
            bookTitle: "Study Book",
            includeImages: false
        )

        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "h2"])
        #expect(preview.candidates.allSatisfy { $0.kind == .chapter })
    }

    @Test func previewIncludesImagesWhenEnabledAndFileExists() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { path in
            path == "/tmp/diagram.png"
        })

        let preview = try generator.preview(
            audiobookID: "book",
            bookTitle: "Study Book",
            includeImages: true
        )

        #expect(preview.candidates.map(\.kind) == [.chapter, .image, .chapter])
        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "img1", "h2"])
    }

    @Test func previewSkipsMissingImages() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in false })

        let preview = try generator.preview(
            audiobookID: "book",
            bookTitle: "Study Book",
            includeImages: true
        )

        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "h2"])
    }

    @Test func previewUsesOneCanonicalHeadingPerChapter() throws {
        let service = try seededService()
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                    ) VALUES
                    ('h1-subtitle', 'book', 'ch1.xhtml', 1, 3, 3, 'heading', 'A Subtitle', NULL, 0, 0, 0, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                        granularity_level, playlist_position, is_enabled, epub_block_id
                    ) VALUES
                    ('t-h1-subtitle', 'book', 'textSegment', 'A Subtitle', 35, 55, 1, 35, 1, 'h1-subtitle')
                    """
            )
        }
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in true })

        let preview = try generator.preview(
            audiobookID: "book",
            bookTitle: "Study Book",
            includeImages: false
        )

        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "h2"])
        #expect(preview.candidates.map(\.chapterIndex) == [0, 1])
    }

    @Test func previewSkipsCandidatesWithoutUsableAudioMapping() throws {
        let service = try seededService()
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                    ) VALUES
                    ('h3', 'book', 'ch3.xhtml', 3, 0, 5, 'heading', 'Chapter 3', NULL, 2, 0, 0, '2026-06-01T00:00:00Z'),
                    ('img2', 'book', 'ch3.xhtml', 3, 1, 6, 'image', NULL, '/tmp/unmapped.png', 2, 0, 0, '2026-06-01T00:00:00Z')
                    """
            )
        }
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in true })

        let preview = try generator.preview(
            audiobookID: "book",
            bookTitle: "Study Book",
            includeImages: true
        )

        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "img1", "h2"])
        #expect(!preview.candidates.contains { $0.mediaTimestamp == 0 })
    }

    @Test func previewCarriesTimelineAudioRange() throws {
        let service = try seededService()
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in true })

        let preview = try generator.preview(
            audiobookID: "book",
            bookTitle: "Study Book",
            includeImages: false
        )
        let first = try #require(preview.candidates.first)

        #expect(first.mediaTimestamp == 10)
        #expect(first.endTimestamp == 100)
        #expect(first.playlistPosition == 10)
    }

    @Test func previewDeduplicatesTimelineRowsAndPrefersEnabledSelection() throws {
        let service = try seededService()
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                        granularity_level, playlist_position, is_enabled, epub_block_id
                    ) VALUES
                    ('t-h1-disabled-stale', 'book', 'textSegment', 'Stale Chapter 1', 1, 2, 1, 1, 0, 'h1'),
                    ('t-h1-enabled-later', 'book', 'textSegment', 'Later Chapter 1', 20, 120, 1, 20, 1, 'h1')
                    """
            )
        }
        let generator = StudyPlanGenerator(db: service.writer, fileExists: { _ in true })

        let preview = try generator.preview(
            audiobookID: "book",
            bookTitle: "Study Book",
            includeImages: false
        )
        let first = try #require(preview.candidates.first)

        #expect(preview.candidates.map(\.sourceBlockID) == ["h1", "h2"])
        #expect(first.mediaTimestamp == 10)
        #expect(first.endTimestamp == 100)
        #expect(first.playlistPosition == 10)
    }

    private func seededService() throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Study Book', 3600, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                        block_kind, text, image_path, chapter_index, is_hidden, is_front_matter, created_at
                    ) VALUES
                    ('front', 'book', 'front.xhtml', 0, 0, 0, 'heading', 'Praise', NULL, -1, 0, 1, '2026-06-01T00:00:00Z'),
                    ('h1', 'book', 'ch1.xhtml', 1, 0, 1, 'heading', 'Chapter 1', NULL, 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('img1', 'book', 'ch1.xhtml', 1, 1, 2, 'image', NULL, '/tmp/diagram.png', 0, 0, 0, '2026-06-01T00:00:00Z'),
                    ('hidden', 'book', 'ch1.xhtml', 1, 2, 3, 'heading', 'Hidden', NULL, 0, 1, 0, '2026-06-01T00:00:00Z'),
                    ('h2', 'book', 'ch2.xhtml', 2, 0, 4, 'heading', 'Chapter 2', NULL, 1, 0, 0, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                        granularity_level, playlist_position, is_enabled, epub_block_id
                    ) VALUES
                    ('t-h1', 'book', 'textSegment', 'Chapter 1', 10, 100, 1, 10, 1, 'h1'),
                    ('t-img1', 'book', 'imageAsset', 'Image', 15, NULL, 1, 15, 1, 'img1'),
                    ('t-h2', 'book', 'textSegment', 'Chapter 2', 100, 200, 1, 100, 1, 'h2')
                    """
            )
        }
        return service
    }
}
