// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import UIKit
import os.log

private nonisolated final class ObserverTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    func set(_ newToken: any NSObjectProtocol) {
        lock.lock()
        defer { lock.unlock() }
        token = newToken
    }

    func removeObserver() {
        lock.lock()
        let currentToken = token
        token = nil
        lock.unlock()

        if let currentToken {
            NotificationCenter.default.removeObserver(currentToken)
        }
    }
}

/// View model for the EPUB reader feed. Loads blocks, builds the card array,
/// tracks the active block for playback sync, and handles search.
@MainActor
@Observable
final class ReaderFeedViewModel {
    private let logger = Logger(category: "ReaderFeed")

    let audiobookID: String
    private let blockDAO: EPubBlockDAO
    private let chapterDAO: ChapterDAO
    private let bookmarkDAO: BookmarkDAO
    private let flashcardDAO: FlashcardDAO
    private let noteDAO: NoteDAO
    private let voiceMemoDAO: VoiceMemoDAO
    private let anchorDAO: AlignmentAnchorDAO
    private let offResolver: OffStateResolver
    /// Playlist folder for `.echoplaylist.json` (audio off lives here). May be nil
    /// for text-only books.
    private let playlistFolderURL: URL?
    /// Cached chapter → backing-track files (filled in `reload`). Single-track m4b
    /// books map their one file to every chapter.
    private var trackFilesByChapter: [Int: [String]] = [:]
    /// Cached off-state per chapter, recomputed in `reload`.
    private(set) var offStateByChapter: [Int: ChapterOffState] = [:]
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

    /// Cached notes grouped by their anchor block ID (repopulated on every reload).
    private var notesByBlockID: [String: [NoteRecord]] = [:]
    /// Cached voice memos grouped by their anchor block ID (repopulated on every reload).
    private var memosByBlockID: [String: [VoiceMemoRecord]] = [:]

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
    /// Audio-chapter groups (one collapsible unit per chapter), rebuilt on reload.
    private(set) var chapterGroups: [ReaderChapterGroup] = []
    /// The feed actually rendered by the collection: collapsed = one header row
    /// per chapter; the open chapter expands inline. Derived from
    /// `chapterGroups` + `openChapterKey`; `sections` stays the full list for the
    /// TOC sheet / pickers.
    private(set) var displaySections: [ReaderCardSection] = []
    /// Per-chapter honest has-audio flag for header-row styling.
    private(set) var chapterHasAudio: [Int: Bool] = [:]
    /// Per-chapter denormalized theme color, so the sticky background still
    /// resolves while scrolling collapsed (header-only) rows. Absent key = no
    /// theme (neutral) — which also clears a stale tint from a closed chapter.
    private(set) var chapterThemeColorByKey: [Int: String] = [:]
    /// Phase-3 two-axis filter (content type × scope). Setting it re-derives the feed.
    var filter: FeedFilter = FeedFilter() {
        didSet {
            guard filter != oldValue else { return }
            if filter.scope != oldValue.scope {
                resolveScope()
            }
            rebuildDisplaySections()
        }
    }

    /// The resolved window for the current scope (nil under `.wholeBook`).
    private(set) var scopeWindow: FeedScopeWindow?

    /// The recap card metadata for the current scoped window (nil under `.wholeBook`).
    private(set) var recap: SessionRecap?

    /// The single expanded chapter (accordion). `nil` = all collapsed.
    private(set) var openChapterKey: Int?
    /// Chapter of the most recent active block, so auto-expand only fires on a
    /// real chapter transition (not every playback tick).
    private var lastPlayingChapterKey: Int?
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

    /// Scopes the feed to a reconstructed session's audio window. `.wholeBook`
    /// = no filter (default). Set this then call `reload()`.
    var sessionScope: SessionScope = .wholeBook {
        didSet {
            guard oldValue != sessionScope else { return }
            reload()
        }
    }

    /// Current search query. nil = show all blocks.
    var searchQuery: String? {
        didSet { reload() }
    }

    var showsNoResults: Bool {
        hasActiveFeedConstraint && !displaySections.contains { !$0.items.isEmpty }
    }

    private var hasActiveFeedConstraint: Bool {
        let hasSearch = searchQuery?.isEmpty == false
        return hasSearch || filter.contentType != .everything || filter.scope != .wholeBook
            || sessionScope != .wholeBook
    }

    /// Retains the timeline observer so it can be removed from nonisolated `deinit`.
    @ObservationIgnored private nonisolated let timelineObserverToken = ObserverTokenBox()

    init(audiobookID: String, db: DatabaseWriter, playlistFolderURL: URL? = nil) {
        self.audiobookID = audiobookID
        self.blockDAO = EPubBlockDAO(db: db)
        self.chapterDAO = ChapterDAO(db: db)
        self.bookmarkDAO = BookmarkDAO(db: db)
        self.flashcardDAO = FlashcardDAO(db: db)
        self.noteDAO = NoteDAO(db: db)
        self.voiceMemoDAO = VoiceMemoDAO(db: db)
        self.anchorDAO = AlignmentAnchorDAO(db: db)
        self.playlistFolderURL = playlistFolderURL
        self.offResolver = OffStateResolver(db: db, folderURL: playlistFolderURL)
        self.db = db
        timelineObserverToken.set(
            NotificationCenter.default.addObserver(
                forName: .timelineItemsIngested,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let viewModel = self else { return }
                Task { @MainActor in
                    viewModel.reload()
                }
            })
    }

    deinit {
        timelineObserverToken.removeObserver()
    }

    /// Load blocks from the database and build the card array.
    func reload() {
        do {
            // Captured in the browse branch; used after timeline is loaded to
            // rebuild chapterGroups with spliced extras (C1 fix).
            var capturedTitlesByKey: [Int: String] = [:]
            var capturedWithAudio: Set<Int> = []

            let blocks: [EPubBlockRecord]
            if let query = searchQuery, !query.isEmpty {
                blocks = try blockDAO.searchBlocks(for: audiobookID, query: query)
                sections = [
                    ReaderCardSection(
                        id: "search", headingStack: ["Search Results"],
                        items: blocks.map { .block($0) })
                ]
                chapterGroups = []
                chapterHasAudio = [:]
                chapterThemeColorByKey = [:]
                openChapterKey = nil
                displaySections = sections
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
                var titlesByKey: [Int: String] = [:]

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
                    titlesByKey[key] = chapterTitle

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
                let withAudio =
                    (try? ChapterAudioStatusResolver(db: db).chaptersWithAudio(
                        audiobookID: audiobookID)) ?? []
                // Capture for Phase-2 post-timeline rebuild (C1 fix: chapterGroups
                // will be rebuilt from the spliced sections after chapterIndexByBlockID
                // is populated, so placement() hits the in-memory cache instead of
                // doing redundant DB reads — I2 fix).
                capturedTitlesByKey = titlesByKey
                capturedWithAudio = withAudio
                chapterGroups = ReaderFeedDisplayBuilder.groups(
                    from: parsedSections, titlesByKey: titlesByKey, chaptersWithAudio: withAudio)
                chapterHasAudio = Dictionary(
                    chapterGroups.map { ($0.chapterKey, $0.hasAudio) },
                    uniquingKeysWith: { a, _ in a })
                // Denormalized per-chapter theme color (first themed block wins) so
                // the sticky background resolves over collapsed header rows.
                var themeByKey: [Int: String] = [:]
                for group in chapterGroups {
                    outer: for section in group.sections {
                        for item in section.items {
                            if case .block(let b) = item, let theme = b.chapterThemeColor {
                                themeByKey[group.chapterKey] = theme
                                break outer
                            }
                        }
                    }
                }
                chapterThemeColorByKey = themeByKey
                // Keep the open chapter only if it still exists after the reload.
                if let open = openChapterKey,
                    !chapterGroups.contains(where: { $0.chapterKey == open })
                {
                    openChapterKey = nil
                }
                // NOTE: Phase-2 splice is deferred to after chapterIndexByBlockID
                // is populated (see below), so placement() cache hits are live (C1+I2 fix).
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
                               ti.segment_key, ti.alignment_status, eb.chapter_index
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
                let segmentKey: String? = row["segment_key"]
                newTimeline.append((start, end, blockID, chapterIndex, segmentKey))
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

            // --- Phase 2 (browse branch only): splice bookmarks + cards now that
            // chapterIndexByBlockID is populated so placement() hits the cache (I2 fix).
            // Rebuild chapterGroups from the spliced sections so displaySections
            // actually includes the extras (C1 fix). ---
            if searchQuery == nil || searchQuery?.isEmpty == true {
                // C2 fix: bucket by section id (not chapter key) so each extra lands
                // in exactly one section. Multi-section chapters no longer receive the
                // same extras array in every section, preventing duplicate snapshot ids.
                let extrasBySection = buildExtrasBySection()
                if !extrasBySection.isEmpty {
                    sections = sections.map { section in
                        guard let extras = extrasBySection[section.id], !extras.isEmpty
                        else { return section }
                        let merged = ReaderFeedDisplayBuilder.spliceExtras(
                            into: section.items, extras: extras)
                        return ReaderCardSection(
                            id: section.id, headingStack: section.headingStack, items: merged)
                    }
                    // Rebuild chapterGroups from the now-spliced sections so
                    // rebuildDisplaySections() surfaces extras in the accordion.
                    chapterGroups = ReaderFeedDisplayBuilder.groups(
                        from: sections,
                        titlesByKey: capturedTitlesByKey,
                        chaptersWithAudio: capturedWithAudio)
                    // Re-derive per-chapter audio flag and theme color from rebuilt groups.
                    chapterHasAudio = Dictionary(
                        chapterGroups.map { ($0.chapterKey, $0.hasAudio) },
                        uniquingKeysWith: { a, _ in a })
                    var themeByKey: [Int: String] = [:]
                    for group in chapterGroups {
                        outer: for section in group.sections {
                            for item in section.items {
                                if case .block(let b) = item, let theme = b.chapterThemeColor {
                                    themeByKey[group.chapterKey] = theme
                                    break outer
                                }
                            }
                        }
                    }
                    chapterThemeColorByKey = themeByKey
                }
                // Recompute reconciled off-state per chapter.
                refreshOffState()
                // Populate note/memo caches for FeedItemInjector (Phase 4).
                let notes = (try? noteDAO.notes(for: audiobookID)) ?? []
                let memos = (try? voiceMemoDAO.memos(for: audiobookID)) ?? []
                notesByBlockID = Dictionary(
                    grouping: notes.filter { $0.epubBlockID != nil },
                    by: { $0.epubBlockID! })
                memosByBlockID = Dictionary(
                    grouping: memos.filter { $0.epubBlockID != nil },
                    by: { $0.epubBlockID! })
                rebuildDisplaySections()
                // Phase 3: re-resolve scope after a reload (covered range depends on freshly
                // loaded blocks; whole-book is a no-op).
                if filter.scope != .wholeBook {
                    resolveScope()
                }
            }

            // Re-publish the track-gated badge dictionaries for the existing scope
            // (whole-book until the first scoped updateActiveBlock call).
            applyTrackScope(currentTrackScope)
        } catch {
            logger.error("Failed to load reader blocks: \(error.localizedDescription)")
        }
    }

    // MARK: - Phase 4: note/memo capture

    /// Persists a free-text note anchored to `blockID` at the current reading
    /// position, then refreshes the feed so it appears inline.
    func addNote(text: String, atBlockID blockID: String) {
        let now = Date().ISO8601Format()
        let note = NoteRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            text: text,
            mediaTimestamp: -1,
            realTimestamp: now,
            isEnabled: true,
            playlistPosition: nil,
            createdAt: now,
            modifiedAt: now,
            epubBlockID: blockID)
        do {
            try noteDAO.insert(note)
        } catch {
            logger.error("addNote failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        reload()
    }

    /// Persists a standalone voice memo (already recorded to `fileURL`) anchored
    /// to `blockID`, then refreshes the feed.
    func addVoiceMemo(fileURL: URL, duration: TimeInterval, atBlockID blockID: String) {
        let now = Date().ISO8601Format()
        let memo = VoiceMemoRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            epubBlockID: blockID,
            mediaTimestamp: -1,
            filePath: fileURL.lastPathComponent,
            duration: duration,
            isEnabled: true,
            createdAt: now,
            modifiedAt: now)
        do {
            try voiceMemoDAO.insert(memo)
        } catch {
            logger.error("addVoiceMemo failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        reload()
    }

    /// Opens (expands) the chapter with the given key, collapsing any other open
    /// chapter. Used by tests and by the session-start auto-expand. No-op if the
    /// key is already open.
    func expandChapter(_ chapterKey: Int) {
        guard chapterKey != openChapterKey else { return }
        openChapterKey = chapterKey
        rebuildDisplaySections()
    }

    // MARK: - Phase 2: extras bucketing

    /// Parse the audio chapter index out of a section id "ch<key>-s<n>".
    /// Front matter is "ch-1-s0" → -1.
    static func chapterKey(ofSectionID id: String) -> Int? {
        guard id.hasPrefix("ch") else { return nil }
        let afterCh = id.dropFirst(2)
        guard let sRange = afterCh.range(of: "-s") else { return nil }
        return Int(afterCh[..<sRange.lowerBound])
    }

    /// Return the id of the last section in `sections` that belongs to the given
    /// chapter key (i.e. whose id has the prefix `"ch{key}-"`). Used to route
    /// unanchored or unknown-anchor extras to the chapter tail so they are not
    /// duplicated across multiple sections.
    private func lastSectionID(forChapterKey key: Int) -> String? {
        let prefix = "ch\(key)-"
        return sections.last(where: { $0.id.hasPrefix(prefix) })?.id
    }

    /// Build `.bookmark`/`.ankiCard` extras bucketed by **section id**, not chapter
    /// key. Each extra is resolved to exactly one target section:
    ///   - Anchored (afterBlockID is known in `cardIndexByBlockID`): the section
    ///     that contains the anchor block.
    ///   - Unanchored / unknown anchor: the chapter's **last** section (tail).
    /// This guarantees each extra appears in exactly one section in `displaySections`,
    /// preventing duplicate snapshot item identifiers that would crash the diffable
    /// data source when an open chapter has ≥ 2 sections. (C2 fix)
    private func buildExtrasBySection() -> [String: [ReaderFeedDisplayBuilder.SplicedExtra]] {
        var bySection: [String: [ReaderFeedDisplayBuilder.SplicedExtra]] = [:]

        /// Resolve placement to a specific section id.
        func targetSectionID(forChapter chapterKey: Int, afterBlockID: String?) -> String {
            // If there is an anchor block, find which section owns it.
            if let blockID = afterBlockID,
                let indexPath = cardIndexByBlockID[blockID],
                sections.indices.contains(indexPath.section)
            {
                return sections[indexPath.section].id
            }
            // Unanchored or unknown anchor → chapter's last section.
            return lastSectionID(forChapterKey: chapterKey)
                ?? "ch\(chapterKey)-s0"
        }

        // Cards: prefer the precise sourceBlockID; else derive from timestamp.
        let cards = (try? flashcardDAO.flashcards(for: audiobookID)) ?? []
        for card in cards {
            let (chapter, blockID) = placement(
                sourceBlockID: card.sourceBlockID, mediaTimestamp: card.mediaTimestamp)
            let sectionID = targetSectionID(forChapter: chapter, afterBlockID: blockID)
            bySection[sectionID, default: []].append(
                .init(item: .ankiCard(card), afterBlockID: blockID))
        }

        // Bookmarks: no source block — always timestamp-derived.
        let bookmarks = (try? bookmarkDAO.bookmarks(for: audiobookID)) ?? []
        for bm in bookmarks {
            let (chapter, blockID) = placement(
                sourceBlockID: nil, mediaTimestamp: bm.mediaTimestamp)
            let sectionID = targetSectionID(forChapter: chapter, afterBlockID: blockID)
            bySection[sectionID, default: []].append(
                .init(item: .bookmark(bm), afterBlockID: blockID))
        }
        return bySection
    }

    /// Resolve an item to `(chapterIndex, afterBlockID?)`. If `sourceBlockID` is
    /// known, look up its chapter directly; otherwise find the alignment anchor at or
    /// before `mediaTimestamp` and use its block. Unresolvable → (-1, nil) (front
    /// matter bucket) so the item is never dropped.
    private func placement(sourceBlockID: String?, mediaTimestamp: TimeInterval)
        -> (chapter: Int, blockID: String?)
    {
        if let sourceBlockID {
            let looked: Int? =
                (chapterIndexByBlockID[sourceBlockID] ?? nil)
                ?? lookupChapter(ofBlock: sourceBlockID, audiobookID: audiobookID)
            if let idx = looked {
                return (idx, sourceBlockID)
            }
        }
        if let block = anchorDAO.block(at: mediaTimestamp, audiobookID: audiobookID),
            let idx = lookupChapter(ofBlock: block, audiobookID: audiobookID)
        {
            return (idx, block)
        }
        return (-1, nil)
    }

    private func lookupChapter(ofBlock blockID: String, audiobookID: String) -> Int? {
        if let cached = chapterIndexByBlockID[blockID] { return cached ?? nil }
        let idx = try? db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT chapter_index FROM epub_block WHERE id = ? AND audiobook_id = ?",
                arguments: [blockID, audiobookID])
        }
        return idx ?? nil
    }

    // MARK: - Phase 2: off-state

    /// Recompute the reconciled off-state for every chapter that has sections.
    func refreshOffState() {
        var result: [Int: ChapterOffState] = [:]
        let keys = Set(sections.compactMap { Self.chapterKey(ofSectionID: $0.id) })
        for key in keys where key >= 0 {
            let files = trackFilesByChapter[key] ?? allTrackFiles()
            result[key] =
                (try? offResolver.resolve(
                    audiobookID: audiobookID, chapterIndex: key, trackFiles: files)) ?? .allOn
        }
        offStateByChapter = result
    }

    /// All track files from the manifest (fallback when a per-chapter map is absent).
    private func allTrackFiles() -> [String] {
        guard let playlistFolderURL,
            let manifest = PlaylistManifestService.read(from: playlistFolderURL)
        else { return [] }
        return manifest.tracks.map(\.file)
    }

    // MARK: - Phase 2: off-state public API

    enum OffKind { case all, audio, epub }

    func chapterOffState(_ chapterIndex: Int) -> ChapterOffState {
        offStateByChapter[chapterIndex] ?? .allOn
    }

    /// Apply an off/on toggle for one chapter, write through the resolver, then
    /// reload so the feed (grey-out + visibility) reflects the new truth.
    func setChapterOff(_ kind: OffKind, on: Bool, chapterIndex: Int) {
        let files = trackFilesByChapter[chapterIndex] ?? allTrackFiles()
        do {
            switch kind {
            case .all:
                try offResolver.setAllOff(
                    on, audiobookID: audiobookID, chapterIndex: chapterIndex, trackFiles: files)
            case .audio:
                try offResolver.setAudioOff(on, trackFiles: files)
            case .epub:
                try offResolver.setEpubOff(on, audiobookID: audiobookID, chapterIndex: chapterIndex)
            }
        } catch {
            // Best-effort: GRDB write may have landed even if the manifest write did
            // not. Log only; the reload below re-reads whatever truth persisted.
            logger.error("setChapterOff failed: \(error.localizedDescription)")
        }
        reload()
    }

    // MARK: - Phase 3: scope resolution

    /// Resolves the current `filter.scope` to a `scopeWindow` + `recap`, off the
    /// stored `audiobookID` (the GRDB UUID used by `playback_event`). Synchronous
    /// GRDB reads on a few rows — within smooth-scroll budget (Phase-3 Trap B).
    private func resolveScope() {
        switch filter.scope {
        case .wholeBook:
            scopeWindow = nil
            recap = nil
        case .lastSession:
            let resolver = FeedScopeResolver(db: db)
            let window = (try? resolver.lastSessionWindow(audiobookID: audiobookID)) ?? nil
            scopeWindow = window
            if let window {
                recap = try? SessionRecapViewModel(db: db).recap(
                    audiobookID: audiobookID, window: window)
                expandChapter(forSessionStart: window.coveredStartPosition)
            } else {
                recap = nil
            }
        case .session(let id, _, _):
            let resolver = FeedScopeResolver(db: db)
            let window = (try? resolver.sessionWindow(id: id, audiobookID: audiobookID)) ?? nil
            scopeWindow = window
            if let window {
                recap = try? SessionRecapViewModel(db: db).recap(
                    audiobookID: audiobookID, window: window)
                expandChapter(forSessionStart: window.coveredStartPosition)
            } else {
                recap = nil
            }
        }
    }

    /// Auto-expands the chapter that contains `position` (book seconds), mapping the
    /// position to a chapter index via timeline_item → epub_block, then opening it
    /// (Phase-3 Trap H — a new auto-expand trigger beyond Phase-1's isPlaying one).
    func expandChapter(forSessionStart position: TimeInterval) {
        let key: Int? =
            (try? db.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT eb.chapter_index
                        FROM timeline_item ti
                        JOIN epub_block eb ON eb.id = ti.epub_block_id
                        WHERE ti.audiobook_id = ?
                          AND ti.audio_start_time <= ?
                          AND eb.chapter_index IS NOT NULL
                        ORDER BY ti.audio_start_time DESC
                        LIMIT 1
                        """, arguments: [audiobookID, position])
            }) ?? nil
        if let key {
            openChapterKey = key
            rebuildDisplaySections()
        }
    }

    // MARK: - Display sections

    /// Applies the current `sessionScope` filter to `input`, returning only the
    /// sections (and their items) whose blocks fall inside the audio window.
    /// Returns `input` unchanged when `sessionScope == .wholeBook`.
    ///
    /// Both `rebuildDisplaySections()` (collapsed accordion feed) and
    /// `sessionScopedSections` (fully-expanded detail feed) delegate here so
    /// the scope logic can't drift between the two callers.
    private func applyScopeFilter(to input: [ReaderCardSection]) -> [ReaderCardSection] {
        guard
            let allowed = SessionScopeReducer.blockIDsInScope(
                audioStartTimeByBlockID: allAudioStartTimeByBlockID,
                scope: sessionScope
            )
        else {
            return input  // .wholeBook — no filter
        }
        // Build the set of chapter indices that have at least one in-scope block
        // so that chapterHeader rows are also correctly gated.
        var chaptersInScope = Set<Int>()
        for section in sections {
            for item in section.items {
                if case .block(let record) = item, allowed.contains(record.id),
                    let chIdx = chapterIndexByBlockID[record.id] ?? nil
                {
                    chaptersInScope.insert(chIdx)
                }
            }
        }
        return input.compactMap { section in
            let keptItems = section.items.filter { item in
                switch item {
                case .block(let record):
                    return allowed.contains(record.id)
                case .chapterHeader(_, let chapterIndex):
                    return chaptersInScope.contains(chapterIndex)
                default:
                    return true  // notes, memos, bookmarks, cards always visible
                }
            }
            guard !keptItems.isEmpty else { return nil }
            return ReaderCardSection(
                id: section.id, headingStack: section.headingStack, items: keptItems)
        }
    }

    /// The full `sections` array filtered to the current `sessionScope`, with
    /// every block's text fully expanded (no accordion collapse).
    ///
    /// Use this in detail views (e.g. `SessionDetailFeedView`) that need all
    /// block text for the scoped window rather than the collapsed TOC rows that
    /// `displaySections` produces.  Returns `sections` unchanged under `.wholeBook`.
    var sessionScopedSections: [ReaderCardSection] {
        applyScopeFilter(to: sections)
    }

    /// Recompute `displaySections` from the current groups + accordion state.
    /// Notes and voice memos (Phase 4) are threaded in via `FeedItemInjector`
    /// on the builder output so they are visible only when their chapter is expanded.
    private func rebuildDisplaySections() {
        // While a search is active, `displaySections` IS the flat search-result list
        // (the search branch of reload() sets it directly and clears `chapterGroups`).
        // Rebuilding here would clobber those results with an empty grouped feed, so a
        // filter/scope/accordion change must not run during search — clearing the
        // search box re-runs reload() and restores the browse feed.
        if let query = searchQuery, !query.isEmpty { return }
        let grouped = ReaderFeedDisplayBuilder.displaySections(
            groups: chapterGroups,
            openChapterKey: openChapterKey)
        let filtered = ReaderFeedDisplayBuilder.applyFilter(
            filter.contentType,
            to: grouped,
            chapterHasAudio: chapterHasAudio)
        // Inject notes/memos after filtering so injected items don't influence
        // the content-type filter (notes are not audio/text blocks), and after
        // the display builder so collapsed chapters keep only their header row.
        let injected = FeedItemInjector.inject(
            into: filtered,
            notesByBlockID: notesByBlockID,
            memosByBlockID: memosByBlockID)

        // Phase 5: restrict to a session's audio window when scoped.
        // Uses allAudioStartTimeByBlockID (fully populated by the time
        // rebuildDisplaySections is called from reload()) so the filter is
        // not gated to a single track. Returns nil for .wholeBook (no-op).
        displaySections = applyScopeFilter(to: injected)
    }

    /// User tapped a chapter header: open it (collapsing any other), or collapse
    /// it if it was already open.
    func toggleChapter(_ chapterKey: Int) {
        let next = FeedAccordion.toggled(current: openChapterKey, tapped: chapterKey)
        guard next != openChapterKey else { return }
        openChapterKey = next
        rebuildDisplaySections()
    }

    /// Ensure the chapter that owns `blockID` is expanded (used before a
    /// scroll-to-active jump so the target row exists in the snapshot).
    func expandChapter(containingBlockID blockID: String) {
        guard let key = chapterKey(forBlockID: blockID), key != openChapterKey else { return }
        openChapterKey = key
        rebuildDisplaySections()
    }

    /// Resolve a block's audio chapter key: prefer the timeline-derived index,
    /// else find the block's section and parse its id.
    private func chapterKey(forBlockID blockID: String) -> Int? {
        if let idx = chapterIndexByBlockID[blockID] ?? nil { return idx }
        if let indexPath = cardIndexByBlockID[blockID],
            sections.indices.contains(indexPath.section)
        {
            return ReaderFeedDisplayBuilder.chapterKey(forSectionID: sections[indexPath.section].id)
        }
        return nil
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
    ///   - currentTrackSegmentKey: Segment scope for segment-local narration tracks.
    ///   - currentTrackChapterIndices: EPUB chapter indices in the playing track.
    ///     `nil` = no scoping (single-track books — strict legacy behavior).
    func updateActiveBlock(
        time: TimeInterval,
        currentTrackSegmentKey: String? = nil,
        currentTrackChapterIndices: Set<Int>?,
        isPlaying: Bool = false
    ) {
        if currentTrackScope != currentTrackChapterIndices {
            applyTrackScope(currentTrackChapterIndices)
        }
        let foundBlockID = ReaderActiveBlockResolver.activeBlockID(
            in: timelineCache,
            time: time,
            currentTrackSegmentKey: currentTrackSegmentKey,
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

        // Auto-expand the chapter being played — but only WHILE PLAYING (so a
        // fresh/resumed-but-paused book stays a collapsed TOC) and only on a real
        // chapter transition (so a manual collapse within the same chapter sticks).
        if isPlaying {
            let playingChapterKey = foundBlockID.flatMap { chapterIndexByBlockID[$0] ?? nil }
            let nextOpen = FeedAccordion.autoExpand(
                current: openChapterKey, playingChapterKey: playingChapterKey,
                lastPlayingChapterKey: lastPlayingChapterKey)
            lastPlayingChapterKey = playingChapterKey
            if nextOpen != openChapterKey {
                openChapterKey = nextOpen
                rebuildDisplaySections()
            }
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
