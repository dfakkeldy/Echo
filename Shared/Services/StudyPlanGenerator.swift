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
                    SELECT
                        eb.id,
                        eb.block_kind,
                        eb.text,
                        eb.image_path,
                        eb.chapter_index,
                        eb.sequence_index,
                        COALESCE(ti.audio_start_time, 0) AS media_timestamp,
                        ti.audio_end_time,
                        ti.playlist_position
                    FROM epub_block eb
                    LEFT JOIN timeline_item ti
                      ON ti.epub_block_id = eb.id
                     AND ti.audiobook_id = eb.audiobook_id
                    WHERE eb.audiobook_id = ?
                      AND eb.is_front_matter = 0
                      AND eb.is_hidden = 0
                      AND (
                        eb.block_kind = 'heading'
                        OR (? = 1 AND eb.block_kind = 'image')
                      )
                    ORDER BY eb.sequence_index
                    """,
                arguments: [audiobookID, includeImages ? 1 : 0]
            )
        }

        let candidates = rows.enumerated().compactMap { offset, row -> StudyPlanCandidate? in
            let blockKind: String = row["block_kind"]
            let sourceBlockID: String = row["id"]
            let chapterIndex: Int? = row["chapter_index"]
            let mediaTimestamp: TimeInterval = row["media_timestamp"]
            let endTimestamp: TimeInterval? = row["audio_end_time"]
            let playlistPosition: TimeInterval? = row["playlist_position"]

            if blockKind == EPubBlockRecord.Kind.heading.rawValue {
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
