// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import UIKit
import os.log

/// View model for the EPUB reader feed. Loads blocks, builds the card array,
/// tracks the active block for playback sync, and handles search.
@MainActor
@Observable
final class ReaderFeedViewModel {
    private let logger = Logger(category: "ReaderFeed")

    let audiobookID: String
    private let blockDAO: EPubBlockDAO
    private let chapterDAO: ChapterDAO
    private let db: DatabaseWriter

    /// Cache mapping time ranges to block IDs for fast lookup during playback.
    /// Carries each row's `chapterIndex` (LEFT JOINed from `epub_block`) so the
    /// active-block resolution can be scoped to the currently-playing track.
    private var timelineCache: [ReaderActiveBlockResolver.TimelineRow] = []

    /// Per-word audio `[start, end)` rows for the whole book, ordered by audio
    /// start time. Consumed by `ReaderActiveBlockResolver.activeWord` to drive
    /// karaoke highlighting within the active block.
    private var wordCache: [ReaderActiveBlockResolver.WordRow] = []
    /// (blockID, wordIndex) of the currently spoken word, for karaoke.
    private(set) var activeWord: (blockID: String, index: Int)?

    /// Full, unscoped alignment statuses keyed by block ID (every timestamped
    /// block in the book). The published `alignmentStatusByBlockID` is derived
    /// from this, gated to the current track.
    private var allAlignmentStatusByBlockID: [String: String] = [:]
    /// Full, unscoped audio start times keyed by block ID.
    private var allAudioStartTimeByBlockID: [String: TimeInterval] = [:]
    /// Chapter index of each timestamped block, used to gate the alignment badge
    /// to the current track.
    private var chapterIndexByBlockID: [String: Int?] = [:]

    /// The chapter-index scope of the most recent `updateActiveBlock` call. Drives
    /// which blocks read as "aligned" in the UI. `nil` = whole-book (no scoping).
    private var currentTrackScope: Set<Int>?

    /// Alignment statuses by block ID, **gated to the current track**. A 5.0s
    /// anchor in chapter 3 must not read as aligned-same-as a 5.0s anchor in
    /// chapter 1, so only blocks belonging to the current track are surfaced.
    private(set) var alignmentStatusByBlockID: [String: String] = [:]
    /// Audio start times by block ID, gated to the current track (UI anchor badge).
    private(set) var audioStartTimeByBlockID: [String: TimeInterval] = [:]

    /// All cards in the feed grouped by sections.
    private(set) var sections: [ReaderCardSection] = []
    /// Publisher-declared TOC entries (NCX/nav) persisted at import, in
    /// preorder. Drives the TOC sheet tree and breadcrumb ancestry.
    private(set) var tocEntries: [EPubTOCEntryRecord] = []
    /// Index of each card by block ID for fast lookup.
    private var cardIndexByBlockID: [String: IndexPath] = [:]

    /// ID of the currently active block (based on playback position).
    var activeBlockID: String?

    // MARK: - Auto-alignment workflow state

    /// Progress state for the auto-alignment pipeline. Bound by the UI sheet.
    var autoAlignmentState = AutoAlignmentState()

    /// In-flight auto-alignment operation. Cancelled on view teardown or user action.
    var autoAlignmentTask: Task<Void, Error>?

    /// Whether the auto-alignment progress sheet is presented.
    var showAutoAlignmentProgress = false

    /// Whether the auto-alignment failure alert is presented.
    var showAutoAlignmentFailedAlert = false

    /// Last auto-alignment error message for the failure alert.
    var autoAlignmentErrorMessage: String?

    /// Current search query. nil = show all blocks.
    var searchQuery: String? {
        didSet { reload() }
    }

    init(audiobookID: String, db: DatabaseWriter) {
        self.audiobookID = audiobookID
        self.blockDAO = EPubBlockDAO(db: db)
        self.chapterDAO = ChapterDAO(db: db)
        self.db = db
    }

    /// Load blocks from the database and build the card array.
    func reload() {
        do {
            let blocks: [EPubBlockRecord]
            if let query = searchQuery, !query.isEmpty {
                blocks = try blockDAO.searchBlocks(for: audiobookID, query: query)
                sections = [
                    ReaderCardSection(
                        id: "search", headingStack: ["Search Results"],
                        items: blocks.map { .block($0) })
                ]
            } else {
                let grouped = try blockDAO.blocksByChapter(for: audiobookID)
                tocEntries = (try? EPubTOCEntryDAO(db: db).entries(for: audiobookID)) ?? []

                // Map TOC entries to block sequence positions: the breadcrumb
                // for any block is the path of the last entry at or before it.
                var sequenceByBlockID: [String: Int] = [:]
                for blocks in grouped.values {
                    for block in blocks { sequenceByBlockID[block.id] = block.sequenceIndex }
                }
                var tocPaths: [(seq: Int, path: [String])] = []
                var tocTargetBlockIDs: Set<String> = []
                var entryPathStack: [String] = []
                for entry in tocEntries {  // DAO returns preorder
                    entryPathStack =
                        Array(entryPathStack.prefix(max(0, entry.depth))) + [entry.title]
                    guard let blockID = entry.blockID,
                        let seq = sequenceByBlockID[blockID]
                    else { continue }
                    tocTargetBlockIDs.insert(blockID)
                    tocPaths.append((seq: seq, path: entryPathStack))
                }
                tocPaths.sort { $0.seq < $1.seq }

                func tocPath(at sequenceIndex: Int) -> [String] {
                    var low = 0
                    var high = tocPaths.count - 1
                    var best: [String] = []
                    while low <= high {
                        let mid = (low + high) / 2
                        if tocPaths[mid].seq <= sequenceIndex {
                            best = tocPaths[mid].path
                            low = mid + 1
                        } else {
                            high = mid - 1
                        }
                    }
                    return best
                }

                var parsedSections: [ReaderCardSection] = []
                let sortedKeys = grouped.keys.sorted()

                var globalActiveHeadings: [String?] = Array(repeating: nil, count: 6)
                var currentHeadingStack: [String] = []
                var audioChaptersWithHeadings: Set<Int> = []

                for key in sortedKeys {
                    guard let chapterBlocks = grouped[key], !chapterBlocks.isEmpty else { continue }

                    let isFrontMatter = key < 0
                    let chapterTitle: String
                    if isFrontMatter {
                        chapterTitle = ""
                    } else {
                        let chapters = try? chapterDAO.chapters(for: audiobookID)
                        let rawTitle = chapters?[safe: key]?.title ?? "Chapter \(key + 1)"
                        chapterTitle = Self.formatChapterTitle(rawTitle)
                    }

                    let groupStartTOCPath =
                        chapterBlocks.first.map { tocPath(at: $0.sequenceIndex) } ?? []
                    if !groupStartTOCPath.isEmpty {
                        currentHeadingStack = groupStartTOCPath
                    } else {
                        let validHeadings = globalActiveHeadings.compactMap { $0 }
                        if globalActiveHeadings[0] != nil {
                            currentHeadingStack = validHeadings
                        } else {
                            currentHeadingStack = [chapterTitle] + validHeadings
                        }
                    }

                    var currentItems: [ReaderCardItem] = []
                    var sectionIndex = 0

                    for block in chapterBlocks {
                        if block.blockKind == EPubBlockRecord.Kind.heading.rawValue,
                            let text = block.text, !text.isEmpty
                        {
                            if !HeadingClassifier.isJunk(text) {
                                if !currentItems.isEmpty {
                                    parsedSections.append(
                                        ReaderCardSection(
                                            id: "ch\(key)-s\(sectionIndex)",
                                            headingStack: currentHeadingStack, items: currentItems))
                                    currentItems = []
                                    sectionIndex += 1
                                }

                                let tocBase = tocPath(at: block.sequenceIndex)
                                if !tocBase.isEmpty {
                                    // Publisher-declared ancestry. A TOC target
                                    // heading IS the path's last element; any
                                    // other heading is a subsection beneath it.
                                    currentHeadingStack =
                                        tocTargetBlockIDs.contains(block.id)
                                        ? tocBase
                                        : tocBase + [text.collapsedWhitespace()]
                                } else {
                                    Self.applyLegacyHeadingCascade(
                                        text: text,
                                        block: block,
                                        audioChapterKey: key,
                                        chapterTitle: chapterTitle,
                                        globalActiveHeadings: &globalActiveHeadings,
                                        audioChaptersWithHeadings: &audioChaptersWithHeadings,
                                        currentHeadingStack: &currentHeadingStack
                                    )
                                }
                            }
                        }
                        currentItems.append(.block(block))
                    }
                    if !currentItems.isEmpty {
                        parsedSections.append(
                            ReaderCardSection(
                                id: "ch\(key)-s\(sectionIndex)", headingStack: currentHeadingStack,
                                items: currentItems))
                    }
                }
                sections = parsedSections
            }

            // Rebuild block ID index.
            cardIndexByBlockID = [:]
            for (sectionIdx, section) in sections.enumerated() {
                for (itemIdx, card) in section.items.enumerated() {
                    if case .block(let block) = card {
                        cardIndexByBlockID[block.id] = IndexPath(item: itemIdx, section: sectionIdx)
                    }
                }
            }

            // Rebuild timeline cache for fast active block lookup. LEFT JOIN
            // epub_block so each row carries the block's chapter_index — the
            // active-block resolution scopes by chapter to the current track,
            // and the alignment badge is gated the same way. (No schema change:
            // the mapping is derived at query time from idx_epub_block_chapter.)
            let rows = try db.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id,
                               ti.alignment_status, eb.chapter_index
                        FROM timeline_item ti
                        LEFT JOIN epub_block eb ON eb.id = ti.epub_block_id
                        WHERE ti.audiobook_id = ? AND ti.epub_block_id IS NOT NULL AND ti.audio_start_time >= 0
                        ORDER BY ti.audio_start_time
                        """, arguments: [audiobookID])
            }

            var newTimeline: [ReaderActiveBlockResolver.TimelineRow] = []
            var newAlignmentStatus: [String: String] = [:]
            var newAudioStartTime: [String: TimeInterval] = [:]
            var newChapterIndex: [String: Int?] = [:]
            for (i, row) in rows.enumerated() {
                guard let start: TimeInterval = row["audio_start_time"],
                    let blockID: String = row["epub_block_id"]
                else { continue }

                let end: TimeInterval
                if let explicitEnd: TimeInterval = row["audio_end_time"] {
                    end = explicitEnd
                } else if i + 1 < rows.count,
                    let nextStart: TimeInterval = rows[i + 1]["audio_start_time"]
                {
                    end = nextStart
                } else {
                    end = start + 3600  // Large fallback for the last item
                }
                let chapterIndex: Int? = row["chapter_index"]
                newTimeline.append((start, end, blockID, chapterIndex))
                newAudioStartTime[blockID] = start
                newChapterIndex[blockID] = chapterIndex
                if let status: String = row["alignment_status"] {
                    newAlignmentStatus[blockID] = status
                }
            }
            timelineCache = newTimeline

            // Load per-word read-along timings for karaoke highlighting. Uses
            // the same writer the timeline query above runs on.
            let words = try WordTimingDAO(db: db).words(forAudiobook: audiobookID)
            wordCache = words.map {
                (
                    start: $0.audioStartTime, end: $0.audioEndTime,
                    blockID: $0.epubBlockID, wordIndex: $0.wordIndex
                )
            }

            allAlignmentStatusByBlockID = newAlignmentStatus
            allAudioStartTimeByBlockID = newAudioStartTime
            chapterIndexByBlockID = newChapterIndex
            // Re-publish the track-gated badge dictionaries for the existing scope
            // (whole-book until the first scoped updateActiveBlock call).
            applyTrackScope(currentTrackScope)
        } catch {
            logger.error("Failed to load reader blocks: \(error.localizedDescription)")
        }
    }

    /// Check if any user-created alignment anchors exist (not auto-generated).
    func hasUserAlignmentAnchors(audiobookID: String) -> Bool {
        (try? db.read { database in
            try Int.fetchOne(
                database,
                sql: """
                        SELECT COUNT(*) FROM alignment_anchor
                        WHERE audiobook_id = ? AND source != 'auto'
                    """, arguments: [audiobookID]) ?? 0 > 0
        }) ?? false
    }

    /// Fetch audio start time for a specific EPUB block.
    func audioStartTime(for epubBlockID: String, audiobookID: String) -> Double? {
        try? db.read { database in
            try Double.fetchOne(
                database,
                sql: """
                        SELECT audio_start_time FROM timeline_item
                        WHERE audiobook_id = ? AND epub_block_id = ?
                        LIMIT 1
                    """, arguments: [audiobookID, epubBlockID])
        }
    }

    /// Whether a block belongs to the given chapter scope. Mirrors the resolver:
    /// `nil` scope = whole-book (everything); otherwise a block is in scope when
    /// its chapter index is in the set, and nil-chapter (front-matter) blocks
    /// count only when the set contains track 0.
    private func blockIsInScope(_ chapterIndex: Int?, scope: Set<Int>?) -> Bool {
        guard let scope else { return true }
        if let chapterIndex { return scope.contains(chapterIndex) }
        return scope.contains(0)
    }

    /// Recomputes the published alignment badge dictionaries so only blocks in the
    /// current track read as "aligned". The displayed start-time value is still
    /// the per-track time; scoping only changes *which* blocks are surfaced.
    private func applyTrackScope(_ scope: Set<Int>?) {
        currentTrackScope = scope
        guard scope != nil else {
            alignmentStatusByBlockID = allAlignmentStatusByBlockID
            audioStartTimeByBlockID = allAudioStartTimeByBlockID
            return
        }
        var gatedStatus: [String: String] = [:]
        var gatedStart: [String: TimeInterval] = [:]
        for (blockID, start) in allAudioStartTimeByBlockID {
            let chapterIndex = chapterIndexByBlockID[blockID] ?? nil
            guard blockIsInScope(chapterIndex, scope: scope) else { continue }
            gatedStart[blockID] = start
            if let status = allAlignmentStatusByBlockID[blockID] {
                gatedStatus[blockID] = status
            }
        }
        alignmentStatusByBlockID = gatedStatus
        audioStartTimeByBlockID = gatedStart
    }

    /// Update the active block based on the current playback position, scoped to
    /// the currently-playing track.
    ///
    /// - Parameters:
    ///   - time: The current **per-track** playback time (`PlayerModel.currentPlaybackTime`).
    ///   - currentTrackChapterIndices: EPUB chapter indices in the playing track.
    ///     `nil` = no scoping (single-track books — strict legacy behavior).
    func updateActiveBlock(time: TimeInterval, currentTrackChapterIndices: Set<Int>?) {
        if currentTrackScope != currentTrackChapterIndices {
            applyTrackScope(currentTrackChapterIndices)
        }
        let foundBlockID = ReaderActiveBlockResolver.activeBlockID(
            in: timelineCache,
            time: time,
            currentTrackChapterIndices: currentTrackChapterIndices
        )
        if activeBlockID != foundBlockID {
            activeBlockID = foundBlockID
        }

        let wordIdx = ReaderActiveBlockResolver.activeWord(
            in: wordCache, time: time, activeBlockID: foundBlockID)
        let newActiveWord = wordIdx.map { (blockID: foundBlockID ?? "", index: $0) }
        if newActiveWord?.blockID != activeWord?.blockID
            || newActiveWord?.index != activeWord?.index
        {
            activeWord = newActiveWord
        }
    }

    /// Index path for a given block ID, if present in the current sections.
    func indexForBlockID(_ blockID: String) -> IndexPath? {
        cardIndexByBlockID[blockID]
    }

    /// Heading-level breadcrumb inference for books without a publisher TOC:
    /// h-tag levels (with part/chapter/section text overrides) cascade into a
    /// six-slot stack, demoting repeat headings within one audio chapter.
    private static func applyLegacyHeadingCascade(
        text: String,
        block: EPubBlockRecord,
        audioChapterKey: Int,
        chapterTitle: String,
        globalActiveHeadings: inout [String?],
        audioChaptersWithHeadings: inout Set<Int>,
        currentHeadingStack: inout [String]
    ) {
        let markers = block.decodedMarkers
        var level: Int? = nil
        if let startMarker = markers.first(where: { $0.type == MarkerType.chapterStart }),
            let parsedLevel = Int(startMarker.payload)
        {
            level = parsedLevel
        }

        // Text-based heuristic override to maintain correct heading hierarchy
        // when structural levels aren't explicitly provided by the EPUB tags.
        let lowerText = text.lowercased().trimmingCharacters(in: .whitespaces)
        let isExplicitTopLevel =
            lowerText.range(of: "^(?:part|book|chapter)\\b", options: .regularExpression) != nil

        if lowerText.range(of: "^(?:part|book)\\b", options: .regularExpression) != nil {
            level = 1
        } else if lowerText.range(of: "^chapter\\b", options: .regularExpression) != nil {
            level = 2
        } else if lowerText.range(of: "^section\\b", options: .regularExpression) != nil {
            level = 3
        }

        // Demote subsequent non-explicit headings in the same audio chapter
        let isFirstHeadingInAudioChapter = !audioChaptersWithHeadings.contains(audioChapterKey)
        if isFirstHeadingInAudioChapter {
            audioChaptersWithHeadings.insert(audioChapterKey)
        } else if !isExplicitTopLevel {
            if let explicit = level, explicit < 3 {
                level = 3
            }
        }

        let finalLevel: Int
        if let explicitLevel = level {
            finalLevel = explicitLevel
        } else {
            // If we already have top-level headings, default to level 3 (section)
            // to avoid blowing away the main Chapter / Part context.
            if globalActiveHeadings[0] != nil || globalActiveHeadings[1] != nil {
                finalLevel = 3
            } else {
                finalLevel = 1
            }
        }

        let depthIndex = max(0, min(5, finalLevel - 1))
        // Collapse interior whitespace so the pinned
        // header never shows legacy line-broken titles.
        globalActiveHeadings[depthIndex] = text.collapsedWhitespace()
        for i in (depthIndex + 1)..<6 {
            globalActiveHeadings[i] = nil
        }

        let validHeadings = globalActiveHeadings.compactMap { $0 }
        if globalActiveHeadings[0] != nil {
            // A valid top-level heading was found in the text!
            // This supersedes the (potentially stale or misaligned) TOC title.
            currentHeadingStack = validHeadings
        } else {
            // No level 1 heading yet, fall back to TOC title for context.
            currentHeadingStack = [chapterTitle] + validHeadings
        }
    }

    /// Formats flattened TOC titles (e.g. "Part One: Chapter One") to extract just the
    /// overarching "Part" title, preventing nested chapter repetition in the feed.
    nonisolated static func formatChapterTitle(_ title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("part ") && lower.contains("chapter ") {
            if let range = title.range(of: ":")
                ?? title.range(of: " - Chapter", options: .caseInsensitive)
            {
                let firstPart = String(title[..<range.lowerBound]).trimmingCharacters(
                    in: .whitespaces)
                if firstPart.lowercased().contains("part") {
                    return firstPart
                }
            }
        }
        return title
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
