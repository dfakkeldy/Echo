// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class VisualListeningViewModel {
    let audiobookID: String

    private(set) var snapshot: VisualListeningSnapshot = .empty
    private(set) var hasVisualListeningContent = false

    var syncPoint: VisualListeningSyncPoint = .midpoint {
        didSet {
            guard syncPoint != oldValue else { return }
            recomputeSnapshot()
        }
    }

    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let logger = Logger(category: "VisualListening")

    private var blocks: [EPubBlockRecord] = []
    private var timeline: [ReaderActiveBlockResolver.TimelineRow] = []
    private var words: [ReaderActiveBlockResolver.WordRow] = []
    private var lastTime: TimeInterval = 0
    private var lastSegmentKey: String?
    private var lastChapterIndices: Set<Int>?

    init(audiobookID: String, db: DatabaseWriter) {
        self.audiobookID = audiobookID
        self.db = db
    }

    func reload() async {
        do {
            blocks = try EPubBlockDAO(db: db).visibleBlocks(for: audiobookID)
            timeline = try Self.loadTimelineRows(audiobookID: audiobookID, db: db)
            words = try WordTimingDAO(db: db)
                .words(forAudiobook: audiobookID)
                .map {
                    (
                        start: $0.audioStartTime,
                        end: $0.audioEndTime,
                        blockID: $0.epubBlockID,
                        wordIndex: $0.wordIndex
                    )
                }
            hasVisualListeningContent = Self.hasContent(blocks: blocks, timeline: timeline)
            recomputeSnapshot()
        } catch {
            blocks = []
            timeline = []
            words = []
            hasVisualListeningContent = false
            snapshot = .empty
            logger.error("Visual listening reload failed: \(error.localizedDescription)")
        }
    }

    func update(
        time: TimeInterval,
        currentTrackSegmentKey: String? = nil,
        currentTrackChapterIndices: Set<Int>? = nil
    ) {
        lastTime = time
        lastSegmentKey = currentTrackSegmentKey
        lastChapterIndices = currentTrackChapterIndices
        recomputeSnapshot()
    }

    private func recomputeSnapshot() {
        guard hasVisualListeningContent else {
            snapshot = .empty
            return
        }

        snapshot = VisualListeningCueResolver.snapshot(
            blocks: blocks,
            timeline: timeline,
            words: words,
            time: lastTime,
            currentTrackSegmentKey: lastSegmentKey,
            currentTrackChapterIndices: lastChapterIndices,
            syncPoint: syncPoint
        )
    }

    private static func loadTimelineRows(
        audiobookID: String,
        db: DatabaseWriter
    ) throws -> [ReaderActiveBlockResolver.TimelineRow] {
        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id,
                           ti.segment_key, eb.chapter_index
                    FROM timeline_item ti
                    LEFT JOIN epub_block eb ON eb.id = ti.epub_block_id
                    WHERE ti.audiobook_id = ? AND ti.epub_block_id IS NOT NULL AND ti.audio_start_time >= 0
                    ORDER BY ti.audio_start_time
                    """,
                arguments: [audiobookID]
            )
        }

        return rows.enumerated().compactMap { index, row in
            guard let start: TimeInterval = row["audio_start_time"],
                let blockID: String = row["epub_block_id"]
            else { return nil }

            let end: TimeInterval
            if let explicitEnd: TimeInterval = row["audio_end_time"] {
                end = explicitEnd
            } else if index + 1 < rows.count,
                let nextStart: TimeInterval = rows[index + 1]["audio_start_time"]
            {
                end = nextStart
            } else {
                end = start + 3_600
            }

            let chapterIndex: Int? = row["chapter_index"]
            let segmentKey: String? = row["segment_key"]
            return (
                start: start,
                end: end,
                blockID: blockID,
                chapterIndex: chapterIndex,
                segmentKey: segmentKey
            )
        }
    }

    private static func hasContent(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow]
    ) -> Bool {
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let hasImage = blocks.contains { block in
            block.blockKind == EPubBlockRecord.Kind.image.rawValue
                && block.imagePath?.isEmpty == false
        }
        let hasSubtitle = timeline.contains { row in
            guard let block = blockByID[row.blockID] else { return false }
            guard block.blockKind != EPubBlockRecord.Kind.image.rawValue else { return false }
            return block.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        return hasImage && hasSubtitle
    }
}
