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
                    
                    let validHeadings = globalActiveHeadings.compactMap { $0 }
                    if globalActiveHeadings[0] != nil {
                        currentHeadingStack = validHeadings
                    } else {
                        currentHeadingStack = [chapterTitle] + validHeadings
                    }
                    
                    var currentItems: [ReaderCardItem] = []
                    var sectionIndex = 0

                    for block in chapterBlocks {
                        if block.blockKind == EPubBlockRecord.Kind.heading.rawValue, let text = block.text, !text.isEmpty {
                            let lower = text.lowercased()
                            let isUtility = lower == "tip" || lower == "warning" || lower == "note" || lower == "caution" || lower == "important"
                            let isTooLong = text.count > 100
                            let isFigure = lower.hasPrefix("figure ") || lower.hasPrefix("table ") || lower.hasPrefix("image ")

                            // Comprehensive front/back matter detection.
                            // Without this, copyright pages, dedications, TOC pages, etc.
                            // create "junk chapters" that clutter the reader feed.
                            let isNonContent = Self.isNonContentHeading(text)

                            if !(isUtility || isTooLong || isNonContent || isFigure) {
                                if !currentItems.isEmpty {
                                    parsedSections.append(ReaderCardSection(id: "ch\(key)-s\(sectionIndex)", headingStack: currentHeadingStack, items: currentItems))
                                    currentItems = []
                                    sectionIndex += 1
                                }
                                
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
                                let isFirstHeadingInAudioChapter = !audioChaptersWithHeadings.contains(key)
                                if isFirstHeadingInAudioChapter {
                                    audioChaptersWithHeadings.insert(key)
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
                                globalActiveHeadings[depthIndex] = text
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

    // MARK: - Heading Classification

    /// Returns `true` when a heading text matches common front-matter or back-matter
    /// patterns that should not create reader-feed section splits.
    ///
    /// EPUBs often contain pages like "Title Page", "Copyright", "Contents", "Also by…"
    /// whose headings were surfacing as junk chapters. This set-based check catches the
    /// most common patterns without being so broad that it swallows legitimate chapter
    /// titles (e.g. "Foreword" or "Introduction" are intentionally kept as content).
    nonisolated static func isNonContentHeading(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        /// Headings that are almost never real chapter content.
        let nonContentExact: Set<String> = [
            // Title / half-title pages
            "title page", "title", "half title", "half-title",
            // Copyright / colophon
            "copyright", "copyright page", "colophon",
            // Dedication / epigraph
            "dedication", "dedications", "epigraph",
            // Table of contents
            "contents", "table of contents", "toc",
            // Publisher / promotional
            "also by", "also by the author", "also available",
            "praise for", "praise", "coming soon",
            "about the publisher", "credits",
            // Lists of figures / tables
            "list of illustrations", "list of figures", "list of tables",
            "cast of characters", "maps", "timeline",
            // Explicit front matter marker
            "front matter", "frontmatter",
            // Bibliographic / index
            "bibliography", "references", "index", "glossary",
            // End notes
            "endnotes", "notes", "footnotes",
            // Author bio
            "about the author", "about the authors",
        ]

        if nonContentExact.contains(lower) {
            return true
        }

        // Prefix checks for variable patterns like "Also by J.R.R. Tolkien"
        let nonContentPrefixes = [
            "also by ", "praise for ", "excerpt from ", "excerpt: ",
            "about the author", "about the publisher",
        ]
        for prefix in nonContentPrefixes {
            if lower.hasPrefix(prefix) {
                return true
            }
        }

        return false
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
