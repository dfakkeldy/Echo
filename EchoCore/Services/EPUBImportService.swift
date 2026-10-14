// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Imports EPUB structure into the application's SQL database and local asset storage.
///
/// Responsibilities:
/// - Parse OPF spine order and XHTML content into ordered blocks
/// - Apply heuristic engine to infer true block structures
/// - Split text into paragraph-level blocks (sentence-level optional for later)
/// - Copy referenced images to app-controlled storage
/// - Write `epub_block` records to the database
/// - Post `timelineItemsIngested` notification to trigger feed reload
///
/// For V1, the EPUB is expected to be provided as an expanded directory.
/// ZIP extraction support requires the ZIPFoundation package.
nonisolated struct EPUBImportService {
    private let logger = Logger(category: "EPUBImport")

    /// Destination for EPUB asset files.
    let assetStorage: EPUBAssetStorage

    init(assetStorage: EPUBAssetStorage = EPUBAssetStorage()) {
        self.assetStorage = assetStorage
    }

    /// Import EPUB structure for an audiobook.
    ///
    /// - Parameters:
    ///   - audiobookID: The audiobook identifier (typically `folderURL.absoluteString`).
    ///   - epubURL: Path to the expanded EPUB directory (or .epub file if ZIPFoundation is available).
    ///   - chapters: Parsed chapter list for chapter-index assignment.
    ///   - bookDuration: Total audiobook duration for timestamp estimation.
    ///
    /// - Returns: Array of inserted `EPubBlockRecord` values.
    func `import`(
        audiobookID: String,
        epubURL: URL,
        chapters: [Chapter],
        bookDuration: TimeInterval?,
        generatedIdentity: GeneratedAnthologyImportIdentity? = nil,
        persistencePolicy: EPUBBlockPersistencePolicy = .replaceAll
    ) async throws -> [EPubBlockRecord] {
        // Parse the canonical block set + stable IDs via the shared driver, then
        // run the shared persist/post-process phase. Text import reuses that
        // phase via the `parse:` overload below.
        let parse = try parseEPUBBlocks(
            audiobookID: audiobookID,
            epubURL: epubURL,
            generatedIdentity: generatedIdentity)
        return try await `import`(
            parse: parse, audiobookID: audiobookID, chapters: chapters,
            bookDuration: bookDuration, assetBaseURL: epubURL,
            persistencePolicy: persistencePolicy)
    }

    /// Persist + post-process a pre-computed block parse (image localization, TOC
    /// resolution, chapter-index assignment, DB write). Shared by EPUB import and
    /// text-document import. For text there are no image blocks (the image-copy
    /// loop self-skips) and the TOC tree is heading-derived.
    func `import`(
        parse: EPUBBlockParse,
        audiobookID: String,
        chapters: [Chapter],
        bookDuration: TimeInterval?,
        assetBaseURL: URL,
        persistencePolicy: EPUBBlockPersistencePolicy = .replaceAll
    ) async throws -> [EPubBlockRecord] {
        // 2. Prepare asset storage directory (for image localization below).
        try assetStorage.prepare(for: audiobookID)

        var allBlocks = parse.blocks

        // 3. Copy images referenced in blocks to local asset storage.
        for idx in allBlocks.indices {
            guard allBlocks[idx].blockKind == EPubBlockRecord.Kind.image.rawValue,
                let imagePath = allBlocks[idx].imagePath
            else { continue }
            let xhtmlURL = parse.spineXHTMLURLByIndex[allBlocks[idx].spineIndex] ?? assetBaseURL
            let sourceURL = resolveImageURL(
                href: imagePath, baseURL: xhtmlURL.deletingLastPathComponent(),
                epubRoot: assetBaseURL, opfDir: parse.opfDir)
            if let localPath = assetStorage.copyImage(
                from: sourceURL, audiobookID: audiobookID,
                filename: URL(fileURLWithPath: imagePath).lastPathComponent)
            {
                allBlocks[idx].imagePath = localPath
            }
        }

        // 4. Resolve the publisher's TOC tree (NCX navPoint / nav ol nesting)
        // and apply the same structure chaptering used by read-only preflight.
        let tocRecords = try Self.resolveTOCEntriesAndAssignChapterIndices(
            parse: parse,
            audiobookID: audiobookID,
            assignsStructureChapterIndices: chapters.isEmpty,
            blocks: &allBlocks)

        // 7. Assign Chapter Index for a book whose audio carries chapter marks.
        // Prefer the publisher TOC whenever its labels line up with the audio
        // chapter list: it names each chapter's exact first block, where the
        // cumulative word-count fraction below can only estimate — and that
        // estimate drifts, because no audiobook is narrated at a uniform
        // words-per-second rate (credits carry no text; contents lists,
        // timelines, and cast pages are read at a different density entirely).
        if !chapters.isEmpty, !allBlocks.isEmpty,
            let tocChapterIndices = AudioChapterTOCAlignment.chapterIndices(
                blocks: allBlocks,
                tocEntries: tocRecords,
                audioChapters: chapters.map {
                    AudioChapterTOCAlignment.AudioChapter(index: $0.index, title: $0.title)
                })
        {
            for index in allBlocks.indices {
                allBlocks[index].chapterIndex = tocChapterIndices[allBlocks[index].id]
            }
        } else if let duration = bookDuration, !chapters.isEmpty, !allBlocks.isEmpty {
            let totalWords = Double(
                allBlocks.reduce(0) {
                    $0 + CommercialAudioAlignmentSource.wordWeight(for: $1)
                }
            )
            if totalWords > 0 {
                var cumulativeWords = 0
                var hasSeenFirstHeading = false
                for i in 0..<allBlocks.count {
                    if allBlocks[i].blockKind == EPubBlockRecord.Kind.heading.rawValue {
                        hasSeenFirstHeading = true
                    }
                    cumulativeWords += CommercialAudioAlignmentSource.wordWeight(
                        for: allBlocks[i]
                    )
                    let estimatedFraction = Double(cumulativeWords) / totalWords
                    let estimatedTime = estimatedFraction * duration
                    if let matchedChapter = chapters.first(where: { ch in
                        estimatedTime >= ch.startSeconds && estimatedTime < ch.endSeconds
                    }) {
                        if matchedChapter.index == 0,
                            !hasSeenFirstHeading,
                            estimatedFraction < 0.25
                        {
                            continue
                        }
                        allBlocks[i].chapterIndex = matchedChapter.index
                    }
                }
            } else {
                let nonCodeBlockCount = allBlocks.reduce(0) { count, block in
                    count + (block.blockKind == EPubBlockRecord.Kind.code.rawValue ? 0 : 1)
                }
                if nonCodeBlockCount > 0 {
                    var nonCodePosition = 0
                    for i in allBlocks.indices {
                        let estimatedFraction =
                            Double(nonCodePosition) / Double(nonCodeBlockCount)
                        let estimatedTime = estimatedFraction * duration
                        if let matchedChapter = chapters.first(where: { chapter in
                            estimatedTime >= chapter.startSeconds
                                && estimatedTime < chapter.endSeconds
                        }) {
                            allBlocks[i].chapterIndex = matchedChapter.index
                        }
                        if allBlocks[i].blockKind != EPubBlockRecord.Kind.code.rawValue {
                            nonCodePosition += 1
                        }
                    }
                }
            }
        }

        // 8. Write blocks to database.
        guard let writer = assetStorage.writer else {
            throw EPUBImportError.databaseNotAvailable
        }
        let blocksToInsert = allBlocks
        let tocRecordsToInsert = tocRecords
        let replaceOutcome: EPUBBlockReplaceOutcome? = try await writer.write { database in
            switch persistencePolicy {
            case .replaceAll:
                return try EPUBImportService.replaceAllPreservingUserState(
                    audiobookID: audiobookID,
                    incomingBlocks: blocksToInsert,
                    tocEntries: tocRecordsToInsert,
                    in: database)
            case .reconcileGenerated:
                try GeneratedAnthologyImportReconciler.reconcile(
                    audiobookID: audiobookID,
                    incomingBlocks: blocksToInsert,
                    tocEntries: tocRecordsToInsert,
                    in: database)
                return nil
            }
        }

        // The rows that were actually written: `.replaceAll` merges the prior
        // row's user-authored columns onto each rebuilt block, so returning the
        // raw parse would misreport hidden/coloured blocks to the caller.
        let persistedBlocks = replaceOutcome?.blocks ?? allBlocks
        if let carryOver = replaceOutcome?.carryOver, carryOver.hadPriorBlocks {
            let summary = carryOver.logSummary
            logger.info("Re-import carry-over for \(audiobookID): \(summary)")
        }

        logger.info(
            "Imported \(persistedBlocks.count) EPUB blocks and \(tocRecords.count) TOC entries for \(audiobookID)"
        )
        return persistedBlocks
    }

    // MARK: - TOC entry resolution

    /// Resolves publisher TOC entries and, when no audio chapters exist,
    /// applies the structure chaptering shared with resolver preflight.
    static func resolveTOCEntriesAndAssignChapterIndices(
        parse: EPUBBlockParse,
        audiobookID: String,
        assignsStructureChapterIndices: Bool,
        blocks: inout [EPubBlockRecord]
    ) throws -> [EPubTOCEntryRecord] {
        var anchorBlockIDBySpine: [Int: [String: String]] = [:]
        var firstHeadingBlockIDBySpine: [Int: String] = [:]
        var firstBlockIDBySpine: [Int: String] = [:]
        for (block, descriptor) in zip(blocks, parse.descriptors) {
            let spineIndex = block.spineIndex
            if firstBlockIDBySpine[spineIndex] == nil { firstBlockIDBySpine[spineIndex] = block.id }
            if firstHeadingBlockIDBySpine[spineIndex] == nil,
                block.blockKind == EPubBlockRecord.Kind.heading.rawValue
            {
                firstHeadingBlockIDBySpine[spineIndex] = block.id
            }
            for anchor in descriptor.anchorIDs
            where anchorBlockIDBySpine[spineIndex]?[anchor] == nil {
                anchorBlockIDBySpine[spineIndex, default: [:]][anchor] = block.id
            }
        }
        let tocRecords = try resolveTOCEntries(
            parse.tocEntryTree,
            audiobookID: audiobookID,
            spine: parse.spine,
            anchorBlockIDBySpine: anchorBlockIDBySpine,
            firstHeadingBlockIDBySpine: firstHeadingBlockIDBySpine,
            firstBlockIDBySpine: firstBlockIDBySpine,
            blocks: &blocks)
        if assignsStructureChapterIndices {
            let chapterIndices = EPUBStructureChaptering.chapterIndices(
                blocks: blocks, tocEntries: tocRecords)
            for index in blocks.indices {
                blocks[index].chapterIndex = chapterIndices[blocks[index].id]
            }
        }
        return tocRecords
    }

    /// Flattens the parsed TOC tree (preorder) into persistable records,
    /// resolving each entry to a block: fragment anchor when the NCX/nav names
    /// one, otherwise the spine's first heading, otherwise its first block.
    /// Entries whose href matches no spine item are dropped with their
    /// children promoted to the parent level.
    static func resolveTOCEntries(
        _ tree: [TOCEntryNode],
        audiobookID: String,
        spine: [SpineItemDescriptor],
        anchorBlockIDBySpine: [Int: [String: String]],
        firstHeadingBlockIDBySpine: [Int: String],
        firstBlockIDBySpine: [Int: String],
        blocks: inout [EPubBlockRecord]
    ) throws -> [EPubTOCEntryRecord] {
        guard !tree.isEmpty else { return [] }

        var spineIndexByHref: [String: Int] = [:]
        var spineIndexByFilename: [String: Int] = [:]
        for (idx, item) in spine.enumerated() {
            let normalized = EPUBStructure.normalizeHref(item.href)
            if spineIndexByHref[normalized] == nil { spineIndexByHref[normalized] = idx }
            let filename = URL(fileURLWithPath: normalized).lastPathComponent
            if spineIndexByFilename[filename] == nil { spineIndexByFilename[filename] = idx }
        }

        var blockArrayIndexByID: [String: Int] = [:]
        for (idx, block) in blocks.enumerated() { blockArrayIndexByID[block.id] = idx }

        var records: [EPubTOCEntryRecord] = []
        var orderCounter = 0

        func resolveSpineIndex(_ href: String) -> Int? {
            let normalized = EPUBStructure.normalizeHref(href)
            if let exact = spineIndexByHref[normalized] { return exact }
            // NCX src paths can be relative to the NCX file's directory while
            // spine hrefs are OPF-relative; fall back to filename equality.
            return spineIndexByFilename[URL(fileURLWithPath: normalized).lastPathComponent]
        }

        func appendEntries(_ nodes: [TOCEntryNode], parentID: String?, depth: Int) throws {
            for node in nodes {
                guard let spineIdx = resolveSpineIndex(node.href) else {
                    try appendEntries(node.children, parentID: parentID, depth: depth)
                    continue
                }

                var resolvedBlockID: String?
                var fragmentResolved = false
                if let fragment = node.fragment,
                    let anchorHit = anchorBlockIDBySpine[spineIdx]?[fragment]
                {
                    resolvedBlockID = anchorHit
                    fragmentResolved = true
                } else {
                    resolvedBlockID =
                        firstHeadingBlockIDBySpine[spineIdx] ?? firstBlockIDBySpine[spineIdx]
                }

                let entryID = "toc-\(audiobookID)-\(orderCounter)"
                records.append(
                    EPubTOCEntryRecord(
                        id: entryID,
                        audiobookID: audiobookID,
                        parentID: parentID,
                        orderIndex: orderCounter,
                        depth: depth,
                        title: node.title,
                        blockID: resolvedBlockID,
                        spineIndex: spineIdx
                    ))
                orderCounter += 1

                if fragmentResolved,
                    let blockID = resolvedBlockID,
                    let arrayIdx = blockArrayIndexByID[blockID]
                {
                    try promoteToHeadingIfTitleMatches(
                        &blocks[arrayIdx], title: node.title, depth: depth)
                }

                try appendEntries(node.children, parentID: entryID, depth: depth + 1)
            }
        }
        try appendEntries(tree, parentID: nil, depth: 0)
        return records
    }

    /// Promotes a fragment-resolved paragraph to a heading when its text is
    /// essentially the TOC entry's title. Publishers mark some section titles
    /// up as layout tables (The Pragmatic Programmer's "Topic N" recipes), so
    /// they never arrive as `<h1>`–`<h6>`. The title-similarity gate keeps
    /// body prose safe when an entry anchors at a regular paragraph.
    private static func promoteToHeadingIfTitleMatches(
        _ block: inout EPubBlockRecord, title: String, depth: Int
    ) throws {
        guard block.blockKind == EPubBlockRecord.Kind.paragraph.rawValue,
            let text = block.text, !text.isEmpty, text.count <= 120,
            titlesEssentiallyMatch(text, title)
        else { return }

        block.blockKind = EPubBlockRecord.Kind.heading.rawValue
        let level = min(max(depth + 1, 1), 6)
        var markers = try block.decodeMarkers()
        markers.insert(
            SyncMarker(type: .chapterStart, payload: String(level), epubCharOffset: 0),
            at: 0
        )
        block.markers = EPubBlockRecord.encodeMarkers(markers)
    }

    /// Case-, punctuation-, and whitespace-insensitive title comparison with a
    /// Levenshtein backstop for minor source/label drift.
    static func titlesEssentiallyMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizedTitleForComparison(a)
        let nb = normalizedTitleForComparison(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        return na.normalizedLevenshteinSimilarity(to: nb) >= 0.85
    }

    private static func normalizedTitleForComparison(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .collapsedWhitespace()
    }

    // MARK: - Image resolution

    private func resolveImageURL(href: String, baseURL: URL, epubRoot: URL, opfDir: URL) -> URL {
        if href.hasPrefix("/") {
            return epubRoot.appendingPathComponent(String(href.dropFirst()))
        }
        if href.contains("://") {
            return URL(fileURLWithPath: href)
        }
        return baseURL.appendingPathComponent(href)
    }
}

// MARK: - Non-destructive `.replaceAll`

/// How the prior `epub_block` rows for a book map onto the rows a fresh parse is
/// about to insert.
///
/// Three passes, each refusing anything it cannot decide 1:1: EXACT id, then the
/// portable `s<i>-b<j>` suffix, then the block's position-free content.
///
/// **The suffix is never used to *reconstruct* an id.** `EPUBBlockParser` emits
/// both `epub-<book>-s<i>-b<j>` and `epub-<book>-generic-s<i>-b<j>`, and both
/// collapse to the same suffix, so rebuilding `"epub-\(book)-\(suffix)"` would
/// silently retarget every generic block onto its non-generic namesake. For the
/// same reason the pass refuses any suffix that is not unique among the leftovers
/// on BOTH sides — an ambiguous suffix is dropped, never guessed.
///
/// **The suffix pass is not an "ids moved" safety net, and cannot be.** On the
/// `.replaceAll` path every incoming id is `epub-<audiobookID>-s<i>-b<j>` and
/// every prior row was fetched by that same `audiobookID`, so the prefixes are
/// equal and an equal suffix *is* an equal id — something the exact pass already
/// claimed. It resolves exactly one thing: a change of id *scheme* (a
/// `-generic-` block meeting its plain namesake).
///
/// **What the content pass is actually for.** Because ids are positional, a
/// replacement edition that merely *inserts* a paragraph does NOT reach it: every
/// prior `s0-bj` still exists in the incoming set, so the exact pass claims them
/// all and user pins stay at the place in the book they were put — which is the
/// intended rule for a pin, and is why the content pass is a fallback rather than
/// the primary match. The pass earns its keep when a prior id is *absent* from
/// the incoming set: a re-chaptered spine (Echo's front/back-matter merge moves a
/// chapter from `s5` to `s3` while its `spine_href` and words are untouched), an
/// id-scheme change the suffix pass had to refuse as ambiguous, or a shorter
/// document. Those are the cases where every affected block used to come out
/// "unresolved" and take its notes, memos and cards down with it.
///
/// **`AlignmentSidecar.sourceIdentity` cannot serve as the content key.** It
/// hashes `portableSuffix(of: block.id)` as its second field, so the same
/// paragraph at a new index hashes differently — the exact property the content
/// pass has to drop. (That same position-sensitivity is why a re-chaptered block
/// is not "source stable" and loses its machine timing rows. Those regenerate;
/// notes do not.) See `EPUBImportService.contentKey(for:)`.
nonisolated struct EPUBBlockIdentityResolution: Sendable {
    /// Prior block id → rebuilt block id.
    var idMap: [String: String] = [:]
    /// Rebuilt block id → the prior row it inherits user state from.
    var priorByRebuiltID: [String: EPubBlockRecord] = [:]
    var matchedExactly = 0
    var matchedBySuffix = 0
    /// Matched by position-free content after both id passes failed — the
    /// renumbered-edition case.
    var matchedByContent = 0
    /// Prior ids no rebuilt block claims. Everything hanging off them is dropped.
    var unresolvedPriorIDs: Set<String> = []
}

/// Tally of what a `.replaceAll` import carried across the block rebuild.
/// Returned out of the GRDB write closure (which is `@Sendable`/nonisolated) so
/// the caller can log it from its own actor.
nonisolated struct EPUBBlockCarryOver: Sendable, Equatable {
    var priorBlockCount = 0
    var matchedExactly = 0
    var matchedBySuffix = 0
    var matchedByContent = 0
    var unresolvedPriorBlocks = 0
    /// Resolved blocks whose `AlignmentSidecar.sourceIdentity` is unchanged —
    /// the only ones allowed to keep *machine* timing rows. Human anchors are
    /// restored regardless; see step 5.
    var sourceStableBlocks = 0
    var anchorsCaptured = 0
    var anchorsRestored = 0
    var anchorsDroppedUnresolved = 0
    var anchorsDroppedSourceChanged = 0
    /// Hand-placed anchors kept on a block whose wording changed. Counted
    /// separately because it is the one place this deliberately keeps a value
    /// that may now be slightly off rather than destroy an unrecoverable one.
    var humanAnchorsKeptAcrossSourceChange = 0
    /// Rows whose block-id column was rewritten to the rebuilt block's id.
    var repinnedRows: [String: Int] = [:]
    /// Rows left pointing at a block id that no longer exists. Deliberately not
    /// repaired: see `.preserveDanglingPointer`.
    var danglingRows: [String: Int] = [:]
    /// Rows deleted: derived rows for a block whose source changed, or
    /// regenerable rows whose block-id column is NOT NULL and whose block is gone.
    var deletedRows: [String: Int] = [:]

    var hadPriorBlocks: Bool { priorBlockCount > 0 }

    var logSummary: String {
        func render(_ label: String, _ counts: [String: Int]) -> String {
            let parts =
                counts
                .filter { $0.value > 0 }
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
            return parts.isEmpty ? "" : " \(label)[\(parts.joined(separator: " "))]"
        }
        return
            "\(priorBlockCount) prior blocks, matched \(matchedExactly) exact + "
            + "\(matchedBySuffix) by suffix + \(matchedByContent) by content, "
            + "\(unresolvedPriorBlocks) dropped, "
            + "\(sourceStableBlocks) source-stable; anchors \(anchorsRestored)/"
            + "\(anchorsCaptured) restored (\(anchorsDroppedUnresolved) block gone, "
            + "\(anchorsDroppedSourceChanged) source changed, "
            + "\(humanAnchorsKeptAcrossSourceChange) hand-placed kept anyway)"
            + render("repinned", repinnedRows)
            + render("dangling", danglingRows)
            + render("deleted", deletedRows)
    }
}

/// What the `.replaceAll` write transaction actually persisted.
nonisolated struct EPUBBlockReplaceOutcome: Sendable {
    let blocks: [EPubBlockRecord]
    let carryOver: EPUBBlockCarryOver
}

extension EPUBImportService {

    /// Every table that stores an `epub_block.id` and owns an `audiobook_id`
    /// column, with the policy for a row whose block did not survive.
    ///
    /// `study_plan_item` is absent on purpose: it has no `audiobook_id` (it
    /// belongs to a `study_plan`) and its pin is SET NULL by the cascade before
    /// this sweep could see it, so it is snapshotted and rewritten separately.
    /// `alignment_anchor` is absent because it is ON DELETE CASCADE — its rows
    /// are gone entirely and are re-inserted rather than re-pinned.
    /// `epub_toc_entry` is absent because `.replaceAll` regenerates it wholesale.
    private nonisolated static var blockIDColumns:
        [(table: String, column: String, orphanPolicy: OrphanPolicy)]
    {
        [
            // NOT NULL block id, and both rows are regenerable: `word_timing` is
            // re-materialized by `AlignmentService.recalculateTimeline`,
            // `pdf_block_page` by the next PDF import. An orphan cannot even be
            // represented, so it goes.
            ("word_timing", "epub_block_id", .deleteRow),
            ("pdf_block_page", "epub_block_id", .deleteRow),
            // `timeline_item` rows sourced from `epub_block` are re-materialized
            // by `recalculateTimeline`, so deleting an orphan is lossless. Rows
            // with any other `source_table` belong to another producer and are
            // left exactly as they were.
            ("timeline_item", "epub_block_id", .deleteEPUBSourcedRow),
            // Irreplaceable user rows. Their pointer is left alone even when it
            // now points nowhere, because a block id is a deterministic function
            // of the document (`epub-<book>-s<i>-b<j>`): a dangling pointer is
            // not garbage, it is the address the row re-attaches to the moment
            // the original document is imported again. NULLing it would convert a
            // recoverable mistake ("I replaced the EPUB with the wrong edition")
            // into permanent loss, and a blanket `NOT EXISTS` sweep would also
            // erase pointers broken by an EARLIER re-import — precisely the rows
            // a corrective re-import exists to heal. So: re-pin what resolved,
            // count what did not, touch nothing else.
            ("note", "epub_block_id", .preserveDanglingPointer),
            ("voice_memo", "epub_block_id", .preserveDanglingPointer),
            ("flashcard", "source_block_id", .preserveDanglingPointer),
            ("narration_quality_issue", "source_block_id", .preserveDanglingPointer),
        ]
    }

    private nonisolated enum OrphanPolicy {
        case deleteRow
        case deleteEPUBSourcedRow
        case preserveDanglingPointer
    }

    /// SQLite binds one parameter per element of an `IN (…)` list; chunk well
    /// under the variable limit so a large book cannot blow the statement.
    private nonisolated static var idChunkSize: Int { 400 }

    /// Replaces a book's parsed blocks without destroying the state that hangs
    /// off them.
    ///
    /// The old `.replaceAll` was literally that — `deleteAll` then re-insert —
    /// which discarded far more than the parse:
    /// - `alignment_anchor.epub_block_id` is ON DELETE **CASCADE**, so every
    ///   anchor for the book died, hand-placed ones included. That also made
    ///   `DocumentImportFinalizer.replaceMachineAnchors`' human-anchor allow-list
    ///   dead code on this path, and forced its `hasExistingAnchors` guard to
    ///   read `false` on every forced re-import.
    /// - `study_plan_item.source_block_id` is ON DELETE **SET NULL**, silently
    ///   un-pinning study plans and breaking their idempotence guard.
    /// - Seven further columns carry an `epub_block.id` with **no foreign key**
    ///   at all, so their rows survived pointing at ids that no longer exist.
    ///
    /// Everything below runs inside the caller's single write transaction, so a
    /// failure anywhere rolls the whole rebuild back.
    ///
    /// Three carry-over rules apply, and the distinctions are the point:
    /// - **User-authored pins follow the block's position.** A note, memo,
    ///   flashcard, QA issue, study-plan item, or highlight colour is re-attached
    ///   whenever the block resolves, even if its wording changed.
    /// - **`is_hidden` follows the block's content.** It is the one carried
    ///   column that *removes* material from the app, so pinning it to a slot
    ///   would let a replacement edition drop new text into a hidden index and
    ///   silently suppress it — invisible in the feed, skipped by narration,
    ///   written to the timeline as `.omitted`. It carries only when the parsed
    ///   content is unchanged.
    /// - **Machine timing rows follow the block's content.** Auto/imported
    ///   anchors, word timings, and EPUB-sourced timeline rows are kept only when
    ///   `AlignmentSidecar.sourceIdentity` is unchanged, because a timestamp for
    ///   text A is not a timestamp for text B. Hand-placed anchors are the
    ///   documented exception (step 5).
    ///
    /// Nothing here NULLs a user row's block pointer. See `.preserveDanglingPointer`.
    nonisolated static func replaceAllPreservingUserState(
        audiobookID: String,
        incomingBlocks: [EPubBlockRecord],
        tocEntries: [EPubTOCEntryRecord],
        in database: Database
    ) throws -> EPUBBlockReplaceOutcome {
        var carryOver = EPUBBlockCarryOver()

        // 1. Snapshot what the delete is about to destroy (CASCADE) or blank
        //    (SET NULL). The FK-less tables survive the delete untouched and are
        //    swept afterwards instead.
        let priorBlocks =
            try EPubBlockRecord
            .filter(Column("audiobook_id") == audiobookID)
            .fetchAll(database)
        let priorAnchors =
            try AlignmentAnchorRecord
            .filter(Column("audiobook_id") == audiobookID)
            .fetchAll(database)
        // `study_plan_item` has no `audiobook_id`; reach it through its plan.
        let priorPlanPins = try Row.fetchAll(
            database,
            sql: """
                SELECT i.id AS item_id, i.source_block_id AS block_id
                FROM study_plan_item i
                JOIN study_plan p ON p.id = i.plan_id
                WHERE p.audiobook_id = ? AND i.source_block_id IS NOT NULL
                """,
            arguments: [audiobookID])

        carryOver.priorBlockCount = priorBlocks.count
        carryOver.anchorsCaptured = priorAnchors.count

        // 2. Resolve prior ids onto rebuilt ids.
        let resolution = EPUBImportService.resolveBlockIdentities(
            prior: priorBlocks, incoming: incomingBlocks)
        carryOver.matchedExactly = resolution.matchedExactly
        carryOver.matchedBySuffix = resolution.matchedBySuffix
        carryOver.matchedByContent = resolution.matchedByContent
        carryOver.unresolvedPriorBlocks = resolution.unresolvedPriorIDs.count

        // 3. Merge the prior row's user-authored columns onto each rebuilt block
        //    and work out which rebuilt blocks still carry the same source.
        var mergedBlocks = incomingBlocks
        var sourceStableIDs: Set<String> = []
        for index in mergedBlocks.indices {
            guard let prior = resolution.priorByRebuiltID[mergedBlocks[index].id] else { continue }
            if AlignmentSidecar.sourceIdentity(for: prior)
                == AlignmentSidecar.sourceIdentity(for: mergedBlocks[index])
            {
                sourceStableIDs.insert(mergedBlocks[index].id)
            }
            EPUBImportService.carryUserState(from: prior, onto: &mergedBlocks[index])
        }
        carryOver.sourceStableBlocks = sourceStableIDs.count

        // 4. The destructive step, now that everything precious is in memory.
        try EPubTOCEntryRecord
            .filter(Column("audiobook_id") == audiobookID)
            .deleteAll(database)
        try EPubBlockRecord
            .filter(Column("audiobook_id") == audiobookID)
            .deleteAll(database)
        for var block in mergedBlocks {
            try block.insert(database)
        }

        // 5. Re-insert the anchors the CASCADE took. Restoring these is what
        //    makes the finalizer's `hasExistingAnchors` guard real: a re-import
        //    whose sidecar turns out to be stale no longer collapses a book's
        //    whole alignment to a crude first/last pair.
        //
        //    A machine anchor is a *measurement of specific words*, so it is kept
        //    only for a block whose `AlignmentSidecar.sourceIdentity` is
        //    unchanged. A hand-placed anchor is not a measurement — `moveToNow`,
        //    `searchResult` and `chapterBoundary` are a person's claim about
        //    where they are in the book, nothing can recompute one, and
        //    `AlignmentAnchorRecord.humanAnchorSources` protects them on every
        //    other path (`DocumentImportFinalizer.replaceMachineAnchors` refuses
        //    to overwrite them). Dropping one because the paragraph was re-worded
        //    would let an edited EPUB silently destroy hand-placed alignment;
        //    keeping a possibly-slightly-off one costs the user one drag.
        for anchor in priorAnchors {
            guard let rebuiltID = resolution.idMap[anchor.epubBlockID] else {
                carryOver.anchorsDroppedUnresolved += 1
                continue
            }
            let isSourceStable = sourceStableIDs.contains(rebuiltID)
            let isHuman = AlignmentAnchorRecord.humanAnchorSources.contains(anchor.source)
            guard isSourceStable || isHuman else {
                carryOver.anchorsDroppedSourceChanged += 1
                continue
            }
            var restored = anchor
            restored.epubBlockID = rebuiltID
            try restored.upsert(database)
            carryOver.anchorsRestored += 1
            if isHuman, !isSourceStable { carryOver.humanAnchorsKeptAcrossSourceChange += 1 }
        }

        // 6. Re-pin `study_plan_item`, which SQLite blanked on the delete.
        //
        //    This is the one pointer that CANNOT keep a dangling id, and the
        //    distinction is the whole reason `.preserveDanglingPointer` is a
        //    per-table policy rather than a global one. `note`, `voice_memo`,
        //    `flashcard` and `narration_quality_issue` carry bare text columns,
        //    so an unresolved pointer survives and re-attaches if the original
        //    document is imported again. `study_plan_item.source_block_id` is a
        //    real foreign key (Schema_V25, `ON DELETE SET NULL`) — writing an id
        //    that no longer exists is rejected by SQLite, and because we are
        //    inside the import transaction that error takes the ENTIRE re-import
        //    down with it. So an unresolvable pin is left as the delete's
        //    SET NULL already left it, and counted as lost.
        var planPinsRestored = 0
        var planPinsLost = 0
        for row in priorPlanPins {
            let itemID: String = row["item_id"]
            let priorBlockID: String = row["block_id"]
            guard let rebuiltID = resolution.idMap[priorBlockID] else {
                planPinsLost += 1
                continue
            }
            try database.execute(
                sql: "UPDATE study_plan_item SET source_block_id = ? WHERE id = ?",
                arguments: [rebuiltID, itemID])
            planPinsRestored += database.changesCount
        }
        if planPinsRestored > 0 { carryOver.repinnedRows["study_plan_item"] = planPinsRestored }
        if planPinsLost > 0 { carryOver.danglingRows["study_plan_item"] = planPinsLost }

        // 7. The FK-less tables kept their rows and their now-stale ids. Rewrite
        //    the renamed pins, then sweep anything still pointing nowhere.
        func countDangling(table: String, predicate: String) throws {
            let dangling =
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \(table) \(predicate)",
                    arguments: [audiobookID]) ?? 0
            if dangling > 0 { carryOver.danglingRows[table, default: 0] += dangling }
        }

        let renames = resolution.idMap.filter { $0.key != $0.value }
        for (table, column, policy) in EPUBImportService.blockIDColumns {
            var repinned = 0
            for (priorID, rebuiltID) in renames {
                try database.execute(
                    sql: """
                        UPDATE \(table) SET \(column) = ?
                        WHERE audiobook_id = ? AND \(column) = ?
                        """,
                    arguments: [rebuiltID, audiobookID, priorID])
                repinned += database.changesCount
            }
            if repinned > 0 { carryOver.repinnedRows[table] = repinned }

            // `NOT EXISTS` against the freshly inserted blocks catches this
            // import's casualties AND any pointer that was already dangling from
            // an earlier re-import. That breadth is safe for a regenerable row
            // and unsafe for a user-authored one, which is why the policy — not
            // the predicate — decides what happens.
            let orphanPredicate = """
                WHERE audiobook_id = ? AND \(column) IS NOT NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM epub_block b WHERE b.id = \(table).\(column)
                  )
                """
            switch policy {
            case .deleteRow:
                try database.execute(
                    sql: "DELETE FROM \(table) \(orphanPredicate)", arguments: [audiobookID])
                if database.changesCount > 0 {
                    carryOver.deletedRows[table, default: 0] += database.changesCount
                }
            case .deleteEPUBSourcedRow:
                try database.execute(
                    sql: """
                        DELETE FROM \(table) \(orphanPredicate)
                          AND source_table = ?
                        """,
                    arguments: [audiobookID, EPubBlockRecord.databaseTableName])
                if database.changesCount > 0 {
                    carryOver.deletedRows[table, default: 0] += database.changesCount
                }
                // Rows from another producer keep their pointer; count what that
                // leaves dangling so the log describes the real end state.
                try countDangling(table: table, predicate: orphanPredicate)
            case .preserveDanglingPointer:
                try countDangling(table: table, predicate: orphanPredicate)
            }
        }

        // 8. Derived timing rows for blocks that survived but whose source text
        //    changed. Keeping them would assert that a timestamp measured
        //    against the old wording still describes the new wording — the exact
        //    drift a re-import is usually run to fix. Mirrors
        //    `GeneratedAnthologyImportReconciler.deleteDerivedRows`.
        let changedRebuiltIDs = Set(resolution.priorByRebuiltID.keys).subtracting(sourceStableIDs)
        if !changedRebuiltIDs.isEmpty {
            let deletedWords = try EPUBImportService.deleteRows(
                table: WordTimingRecord.databaseTableName, column: "epub_block_id",
                audiobookID: audiobookID, blockIDs: changedRebuiltIDs,
                extraPredicate: nil, extraArguments: [], in: database)
            if deletedWords > 0 {
                carryOver.deletedRows[WordTimingRecord.databaseTableName, default: 0] +=
                    deletedWords
            }
            let deletedTimeline = try EPUBImportService.deleteRows(
                table: TimelineItem.databaseTableName, column: "epub_block_id",
                audiobookID: audiobookID, blockIDs: changedRebuiltIDs,
                extraPredicate: "source_table = ?",
                extraArguments: [EPubBlockRecord.databaseTableName], in: database)
            if deletedTimeline > 0 {
                carryOver.deletedRows[TimelineItem.databaseTableName, default: 0] += deletedTimeline
            }
        }

        for var tocEntry in tocEntries {
            try tocEntry.insert(database)
        }

        return EPUBBlockReplaceOutcome(blocks: mergedBlocks, carryOver: carryOver)
    }

    /// Copies the columns a user (not the parser) authored from the prior row
    /// onto its rebuilt counterpart.
    ///
    /// The first six fields mirror `GeneratedAnthologyImportReconciler.reconcile`
    /// exactly, on purpose: two persistence policies that disagree about which
    /// columns are user-owned would be a bug waiting to happen.
    ///
    /// `narrationText` is the one field this adds, and it is conditional. For
    /// prose it holds an FM-refined rewrite (one Foundation Models call per
    /// value), so it is worth carrying — but only when the text is byte
    /// identical, because a refinement of text A is not valid narration for text
    /// B. For code blocks the parser always supplies the block's spoken cue, so
    /// the incoming value is non-nil and is left alone.
    ///
    /// `is_hidden`/`hidden_reason` are gated on `hasSameParsedContent` for the
    /// reason given on `replaceAllPreservingUserState`: they are the only carried
    /// columns that make content disappear, so they must describe *these words*,
    /// not this slot.
    nonisolated static func carryUserState(
        from prior: EPubBlockRecord, onto rebuilt: inout EPubBlockRecord
    ) {
        rebuilt.cardColor = prior.cardColor
        rebuilt.chapterThemeColor = prior.chapterThemeColor
        if EPUBImportService.hasSameParsedContent(prior, rebuilt) {
            rebuilt.isHidden = prior.isHidden
            rebuilt.hiddenReason = prior.hiddenReason
        }
        rebuilt.createdAt = prior.createdAt ?? rebuilt.createdAt
        rebuilt.modifiedAt = prior.modifiedAt
        if rebuilt.narrationText == nil, prior.text == rebuilt.text {
            rebuilt.narrationText = prior.narrationText
        }
    }

    /// A block's text with runs of whitespace collapsed, so a re-flowed or
    /// re-indented XHTML source does not read as new content.
    nonisolated static func normalizedBlockText(_ block: EPubBlockRecord) -> String {
        (block.text ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Position-free identity for a block's parsed content, used to re-attach a
    /// block whose index moved.
    ///
    /// Deliberately NOT `AlignmentSidecar.sourceIdentity`: that hashes the
    /// portable `s<i>-b<j>` suffix, which is exactly the part a renumbered
    /// edition changes. `spineHref` stays in the key so a note can never migrate
    /// to identical boilerplate in a different chapter file — a wrong re-attach
    /// is worse than none.
    ///
    /// `nil` for a block with no distinguishing text (an image, a blank
    /// paragraph). Those must never be content-matched, only matched by id.
    nonisolated static func contentKey(for block: EPubBlockRecord) -> String? {
        let normalized = EPUBImportService.normalizedBlockText(block)
        guard !normalized.isEmpty else { return nil }
        let fields = [block.spineHref, block.blockKind, block.codeLanguage ?? "", normalized]
        // Length-prefixed so no field boundary can be forged, matching
        // `AlignmentSidecar.sourceIdentity`.
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Whether two rows describe the same parsed content, wherever it sits.
    /// Total where `contentKey` is partial: two text-less blocks compare equal,
    /// which is what carrying an `is_hidden` flag on an image block needs.
    nonisolated static func hasSameParsedContent(
        _ lhs: EPubBlockRecord, _ rhs: EPubBlockRecord
    ) -> Bool {
        lhs.blockKind == rhs.blockKind && lhs.spineHref == rhs.spineHref
            && lhs.codeLanguage == rhs.codeLanguage
            && EPUBImportService.normalizedBlockText(lhs)
                == EPUBImportService.normalizedBlockText(rhs)
    }

    /// See `EPUBBlockIdentityResolution` for why exact ids win, why an ambiguous
    /// portable suffix is refused rather than guessed, and why the suffix pass
    /// alone cannot survive a renumbered edition.
    nonisolated static func resolveBlockIdentities(
        prior: [EPubBlockRecord],
        incoming: [EPubBlockRecord]
    ) -> EPUBBlockIdentityResolution {
        var result = EPUBBlockIdentityResolution()
        let incomingIDs = Set(incoming.map(\.id))

        var unmatchedPrior: [EPubBlockRecord] = []
        var claimedIncomingIDs: Set<String> = []
        for block in prior {
            if incomingIDs.contains(block.id) {
                result.idMap[block.id] = block.id
                result.priorByRebuiltID[block.id] = block
                claimedIncomingIDs.insert(block.id)
                result.matchedExactly += 1
            } else {
                unmatchedPrior.append(block)
            }
        }
        guard !unmatchedPrior.isEmpty else { return result }

        var priorIDsBySuffix: [String: [String]] = [:]
        for block in unmatchedPrior {
            priorIDsBySuffix[AlignmentSidecar.portableSuffix(of: block.id), default: []]
                .append(block.id)
        }
        var incomingIDsBySuffix: [String: [String]] = [:]
        for block in incoming where !claimedIncomingIDs.contains(block.id) {
            incomingIDsBySuffix[AlignmentSidecar.portableSuffix(of: block.id), default: []]
                .append(block.id)
        }

        var stillUnmatched: [EPubBlockRecord] = []
        for block in unmatchedPrior {
            let suffix = AlignmentSidecar.portableSuffix(of: block.id)
            guard priorIDsBySuffix[suffix]?.count == 1,
                let candidates = incomingIDsBySuffix[suffix],
                candidates.count == 1
            else {
                stillUnmatched.append(block)
                continue
            }
            result.idMap[block.id] = candidates[0]
            result.priorByRebuiltID[candidates[0]] = block
            claimedIncomingIDs.insert(candidates[0])
            result.matchedBySuffix += 1
        }
        guard !stillUnmatched.isEmpty else { return result }

        // Content pass: the only one that can re-attach a block whose id is not
        // in the incoming set at all, because it never looks at an id. Same 1:1
        // discipline as the suffix pass — a key that is not unique among the
        // leftovers on BOTH sides is refused, so repeated boilerplate ("* * *")
        // can never claim someone's note.
        var priorIDsByContent: [String: [String]] = [:]
        for block in stillUnmatched {
            guard let key = EPUBImportService.contentKey(for: block) else { continue }
            priorIDsByContent[key, default: []].append(block.id)
        }
        var incomingIDsByContent: [String: [String]] = [:]
        for block in incoming where !claimedIncomingIDs.contains(block.id) {
            guard let key = EPUBImportService.contentKey(for: block) else { continue }
            incomingIDsByContent[key, default: []].append(block.id)
        }

        for block in stillUnmatched {
            guard let key = EPUBImportService.contentKey(for: block),
                priorIDsByContent[key]?.count == 1,
                let candidates = incomingIDsByContent[key],
                candidates.count == 1
            else {
                result.unresolvedPriorIDs.insert(block.id)
                continue
            }
            result.idMap[block.id] = candidates[0]
            result.priorByRebuiltID[candidates[0]] = block
            result.matchedByContent += 1
        }
        return result
    }

    /// Chunked `DELETE … WHERE <column> IN (…)`, scoped to one book.
    private nonisolated static func deleteRows(
        table: String,
        column: String,
        audiobookID: String,
        blockIDs: Set<String>,
        extraPredicate: String?,
        extraArguments: [String],
        in database: Database
    ) throws -> Int {
        var deleted = 0
        let ids = Array(blockIDs)
        for start in stride(from: 0, to: ids.count, by: EPUBImportService.idChunkSize) {
            let chunk = Array(ids[start..<min(start + EPUBImportService.idChunkSize, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            var sql =
                "DELETE FROM \(table) WHERE audiobook_id = ? AND \(column) IN (\(placeholders))"
            var values: [String] = [audiobookID]
            values.append(contentsOf: chunk)
            if let extraPredicate {
                sql += " AND \(extraPredicate)"
                values.append(contentsOf: extraArguments)
            }
            try database.execute(
                sql: sql, arguments: StatementArguments(values.map(\.databaseValue)))
            deleted += database.changesCount
        }
        return deleted
    }
}
