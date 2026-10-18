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

    /// Blocks sorted the same way `VisualListeningCueResolver.snapshot` orders
    /// them internally, and the block-ID lookup built from that order. Both are
    /// rebuilt once per `reload()` so `recomputeSnapshot()` doesn't re-sort and
    /// re-key the whole book on every playback tick.
    private var orderedBlocks: [EPubBlockRecord] = []
    private var blocksByID: [String: EPubBlockRecord] = [:]
    /// Cached visual cues for the current scope, consumed by the prepared-cues
    /// snapshot path. Rebuilt only when the scope it was computed for
    /// (`preparedScope`) no longer matches the current segment/chapter/sync-point
    /// scope — nil right after `reload()` so a fresh book always rebuilds even
    /// when its scope happens to equal the previous book's.
    private var preparedCues: [VisualListeningVisualCue] = []
    private var preparedScope:
        (segmentKey: String?, chapters: Set<Int>?, syncPoint: VisualListeningSyncPoint)?

    init(audiobookID: String, db: DatabaseWriter) {
        self.audiobookID = audiobookID
        self.db = db
    }

    func reload() async {
        do {
            blocks = try EPubBlockDAO(db: db).visibleBlocks(for: audiobookID)
            orderedBlocks = blocks.sorted { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex {
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
            blocksByID = Dictionary(uniqueKeysWithValues: orderedBlocks.map { ($0.id, $0) })
            preparedCues = []
            preparedScope = nil
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
            orderedBlocks = []
            blocksByID = [:]
            preparedCues = []
            preparedScope = nil
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

        // Rebuild the prepared cues only when the scope they were computed for
        // has changed (including right after `reload()`, when `preparedScope`
        // is nil). Otherwise reuse them — this is the whole point of the
        // cache: skip the per-tick sort + dictionary rebuild + cue derivation.
        let scopeChanged: Bool
        if let preparedScope {
            scopeChanged =
                lastSegmentKey != preparedScope.segmentKey
                || lastChapterIndices != preparedScope.chapters
                || syncPoint != preparedScope.syncPoint
        } else {
            scopeChanged = true
        }
        if scopeChanged {
            preparedCues = VisualListeningCueResolver.visualCues(
                blocks: orderedBlocks,
                blocksByID: blocksByID,
                timeline: timeline,
                currentTrackSegmentKey: lastSegmentKey,
                currentTrackChapterIndices: lastChapterIndices,
                syncPoint: syncPoint
            )
            preparedScope = (
                segmentKey: lastSegmentKey, chapters: lastChapterIndices, syncPoint: syncPoint
            )
        }

        snapshot = VisualListeningCueResolver.snapshot(
            preparedCues: preparedCues,
            blocksByID: blocksByID,
            words: words,
            timeline: timeline,
            time: lastTime,
            currentTrackSegmentKey: lastSegmentKey,
            currentTrackChapterIndices: lastChapterIndices
        )
    }

    private static func hasContent(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow]
    ) -> Bool {
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let hasVisual = blocks.contains { block in
            switch EPubBlockRecord.Kind(rawValue: block.blockKind) {
            case .image: return block.imagePath?.isEmpty == false
            case .code: return block.text?.isEmpty == false
            default: return false
            }
        }
        let hasSubtitle = timeline.contains { row in
            guard let block = blockByID[row.blockID] else { return false }
            let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
            switch kind {
            case .code:
                // A valid code row always has subtitle prose: its narration cue,
                // or the resolver's defensive "Code listing." fallback.
                return block.text?.isEmpty == false
            case .image:
                return false
            default:
                return block.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    == false
            }
        }

        return hasVisual && hasSubtitle
    }
}
