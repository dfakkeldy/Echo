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
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "ReaderFeed")

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
    /// Index of each card by block ID for fast lookup.
    private var cardIndexByBlockID: [String: IndexPath] = [:]

    /// ID of the currently active block (based on playback position).
    var activeBlockID: String?

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
                var parsedSections: [ReaderCardSection] = []
                let sortedKeys = grouped.keys.sorted()
                
                for key in sortedKeys {
                    guard let chapterBlocks = grouped[key], !chapterBlocks.isEmpty else { continue }
                    
                    let isFrontMatter = key < 0
                    let chapterTitle: String
                    if isFrontMatter {
                        chapterTitle = ""
                    } else {
                        let chapters = try? chapterDAO.chapters(for: audiobookID)
                        chapterTitle = chapters?[safe: key]?.title ?? "Chapter \(key + 1)"
                    }
                    
                    var currentHeadingStack: [String] = [chapterTitle]
                    var currentItems: [ReaderCardItem] = []
                    var sectionIndex = 0

                    for block in chapterBlocks {
                        if block.blockKind == EPubBlockRecord.Kind.heading.rawValue, let text = block.text, !text.isEmpty {
                            let lower = text.lowercased()
                            let isUtility = lower == "tip" || lower == "warning" || lower == "note" || lower == "caution" || lower == "important"
                            let isTooLong = text.count > 100
                            let isFrontMatterHeader = lower.contains("front matter") || lower == "title" || lower == "copyright"
                            let isFigure = lower.hasPrefix("figure ") || lower.hasPrefix("table ") || lower.hasPrefix("image ")
                            
                            if !(isUtility || isTooLong || isFrontMatterHeader || isFigure) {
                                if !currentItems.isEmpty {
                                    parsedSections.append(ReaderCardSection(id: "ch\(key)-s\(sectionIndex)", headingStack: currentHeadingStack, items: currentItems))
                                    currentItems = []
                                    sectionIndex += 1
                                }
                                currentHeadingStack = [chapterTitle, text]
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
