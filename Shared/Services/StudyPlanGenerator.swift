// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyPlanGenerator {
    let db: DatabaseWriter
    private let fileExists: @Sendable (String) -> Bool

    init(
        db: DatabaseWriter,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.db = db
        self.fileExists = fileExists
    }

    func preview(audiobookID: String, bookTitle: String, includeImages: Bool) throws -> StudyPlanPreview {
        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    WITH ranked_timeline AS (
                        SELECT
                            ti.audiobook_id,
                            ti.epub_block_id,
                            ti.audio_start_time,
                            ti.audio_end_time,
                            ti.playlist_position,
                            ROW_NUMBER() OVER (
                                PARTITION BY ti.audiobook_id, ti.epub_block_id
                                ORDER BY
                                    ti.is_enabled DESC,
                                    CASE WHEN ti.playlist_position IS NULL THEN 1 ELSE 0 END,
                                    ti.playlist_position,
                                    ti.audio_start_time,
                                    ti.id
                            ) AS timeline_rank
                        FROM timeline_item ti
                        WHERE ti.audiobook_id = ?
                          AND ti.epub_block_id IS NOT NULL
                    )
                    SELECT
                        eb.id,
                        eb.block_kind,
                        eb.text,
                        eb.image_path,
                        eb.chapter_index,
                        eb.sequence_index,
                        ti.audio_start_time AS media_timestamp,
                        ti.audio_end_time,
                        ti.playlist_position
                    FROM epub_block eb
                    LEFT JOIN ranked_timeline ti
                      ON ti.epub_block_id = eb.id
                     AND ti.audiobook_id = eb.audiobook_id
                     AND ti.timeline_rank = 1
                    WHERE eb.audiobook_id = ?
                      AND eb.is_front_matter = 0
                      AND eb.is_hidden = 0
                      AND (
                        eb.block_kind = 'heading'
                        OR (? = 1 AND eb.block_kind = 'image')
                      )
                    ORDER BY eb.sequence_index, eb.id
                    """,
                arguments: [audiobookID, audiobookID, includeImages ? 1 : 0]
            )
        }

        var seenChapterIndexes: Set<Int> = []
        let candidates = rows.enumerated().compactMap { offset, row -> StudyPlanCandidate? in
            let blockKind: String = row["block_kind"]
            let sourceBlockID: String = row["id"]
            let chapterIndex: Int? = row["chapter_index"]
            let endTimestamp: TimeInterval? = row["audio_end_time"]
            let playlistPosition: TimeInterval? = row["playlist_position"]
            let mediaTimestamp: TimeInterval? = row["media_timestamp"]

            guard let mediaTimestamp, mediaTimestamp >= 0 else {
                return nil
            }

            if blockKind == EPubBlockRecord.Kind.heading.rawValue {
                guard let chapterIndex,
                      seenChapterIndexes.insert(chapterIndex).inserted else {
                    return nil
                }

                let trimmedTitle = ((row["text"] as String?) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return StudyPlanCandidate(
                    id: "chapter-\(sourceBlockID)",
                    kind: .chapter,
                    sourceBlockID: sourceBlockID,
                    chapterIndex: chapterIndex,
                    ordinal: offset,
                    title: trimmedTitle.isEmpty ? "Chapter" : trimmedTitle,
                    defaultIncluded: true,
                    imagePath: nil,
                    mediaTimestamp: max(0, mediaTimestamp),
                    endTimestamp: endTimestamp,
                    playlistPosition: playlistPosition
                )
            }

            guard blockKind == EPubBlockRecord.Kind.image.rawValue,
                  let imagePath = row["image_path"] as String?,
                  fileExists(imagePath) else {
                return nil
            }

            let chapterLabel = chapterIndex.map { "Chapter \($0 + 1)" } ?? "this chapter"
            return StudyPlanCandidate(
                id: "image-\(sourceBlockID)",
                kind: .image,
                sourceBlockID: sourceBlockID,
                chapterIndex: chapterIndex,
                ordinal: offset,
                title: "Review this image from \(chapterLabel)",
                defaultIncluded: true,
                imagePath: imagePath,
                mediaTimestamp: max(0, mediaTimestamp),
                endTimestamp: endTimestamp,
                playlistPosition: playlistPosition
            )
        }

        return StudyPlanPreview(audiobookID: audiobookID, bookTitle: bookTitle, candidates: candidates)
    }
}
