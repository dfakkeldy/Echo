import Foundation
import UIKit
import Observation
import GRDB
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

    /// Cache mapping time ranges to block IDs for fast O(log N) lookup during playback.
    private var timelineCache: [(start: TimeInterval, end: TimeInterval, blockID: String)] = []
    
    /// Cache of alignment statuses by block ID.
    private(set) var alignmentStatusByBlockID: [String: String] = [:]
    /// Cache of audio start times by block ID (used for UI display of anchors).
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
                sections = [ReaderCardSection(id: "search", headingStack: ["Search Results"], items: blocks.map { .block($0) })]
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
                    entryPathStack = Array(entryPathStack.prefix(max(0, entry.depth))) + [entry.title]
                    guard let blockID = entry.blockID,
                          let seq = sequenceByBlockID[blockID] else { continue }
                    tocTargetBlockIDs.insert(blockID)
                    tocPaths.append((seq: seq, path: entryPathStack))
                }
                tocPaths.sort { $0.seq < $1.seq }

                func tocPath(at sequenceIndex: Int) -> [String] {
                    var low = 0, high = tocPaths.count - 1
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

                    let groupStartTOCPath = chapterBlocks.first.map { tocPath(at: $0.sequenceIndex) } ?? []
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
                        if block.blockKind == EPubBlockRecord.Kind.heading.rawValue, let text = block.text, !text.isEmpty {
                            if !HeadingClassifier.isJunk(text) {
                                if !currentItems.isEmpty {
                                    parsedSections.append(ReaderCardSection(id: "ch\(key)-s\(sectionIndex)", headingStack: currentHeadingStack, items: currentItems))
                                    currentItems = []
                                    sectionIndex += 1
                                }
                                
                                let tocBase = tocPath(at: block.sequenceIndex)
                                if !tocBase.isEmpty {
                                    // Publisher-declared ancestry. A TOC target
                                    // heading IS the path's last element; any
                                    // other heading is a subsection beneath it.
                                    currentHeadingStack = tocTargetBlockIDs.contains(block.id)
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
                        parsedSections.append(ReaderCardSection(id: "ch\(key)-s\(sectionIndex)", headingStack: currentHeadingStack, items: currentItems))
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
            
            // Rebuild timeline cache for fast active block lookup
            let rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ti.audio_start_time, ti.audio_end_time, ti.epub_block_id, ti.alignment_status
                    FROM timeline_item ti
                    WHERE ti.audiobook_id = ? AND ti.epub_block_id IS NOT NULL AND ti.audio_start_time >= 0
                    ORDER BY ti.audio_start_time
                    """, arguments: [audiobookID])
            }
            
            var newTimeline: [(start: TimeInterval, end: TimeInterval, blockID: String)] = []
            var newAlignmentStatus: [String: String] = [:]
            var newAudioStartTime: [String: TimeInterval] = [:]
            for (i, row) in rows.enumerated() {
                guard let start: TimeInterval = row["audio_start_time"],
                      let blockID: String = row["epub_block_id"] else { continue }
                      
                let end: TimeInterval
                if let explicitEnd: TimeInterval = row["audio_end_time"] {
                    end = explicitEnd
                } else if i + 1 < rows.count, let nextStart: TimeInterval = rows[i + 1]["audio_start_time"] {
                    end = nextStart
                } else {
                    end = start + 3600 // Large fallback for the last item
                }
                newTimeline.append((start, end, blockID))
                newAudioStartTime[blockID] = start
                if let status: String = row["alignment_status"] {
                    newAlignmentStatus[blockID] = status
                }
            }
            timelineCache = newTimeline
            alignmentStatusByBlockID = newAlignmentStatus
            audioStartTimeByBlockID = newAudioStartTime
        } catch {
            logger.error("Failed to load reader blocks: \(error.localizedDescription)")
        }
    }

    /// Update the active block based on current playback position using binary search.
    func updateActiveBlock(time: TimeInterval) {
        var low = 0
        var high = timelineCache.count - 1
        var foundBlockID: String? = nil

        while low <= high {
            let mid = low + (high - low) / 2
            let item = timelineCache[mid]
            
            if time >= item.start && time < item.end {
                foundBlockID = item.blockID
                break
            } else if time < item.start {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        
        if activeBlockID != foundBlockID {
            activeBlockID = foundBlockID
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
           let parsedLevel = Int(startMarker.payload) {
            level = parsedLevel
        }

        // Text-based heuristic override to maintain correct heading hierarchy
        // when structural levels aren't explicitly provided by the EPUB tags.
        let lowerText = text.lowercased().trimmingCharacters(in: .whitespaces)
        let isExplicitTopLevel = lowerText.range(of: "^(?:part|book|chapter)\\b", options: .regularExpression) != nil

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
            if let range = title.range(of: ":") ?? title.range(of: " - Chapter", options: .caseInsensitive) {
                let firstPart = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if firstPart.lowercased().contains("part") {
                    return firstPart
                }
            }
        }
        return title
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
