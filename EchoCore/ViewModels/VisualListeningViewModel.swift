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
            timeline = try TimelineRowLoader.rows(audiobookID: audiobookID, db: db)
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
