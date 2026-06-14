import Foundation
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
struct EPUBImportService {
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
        bookDuration: TimeInterval?
    ) async throws -> [EPubBlockRecord] {
        // 1. Parse the canonical block set + stable IDs via the shared driver.
        // This is the same driver the macOS aligner uses, so block IDs match
        // across platforms (CODE_AUDIT.md §5.1 / Phase A1).
        let parse = try parseEPUBBlocks(audiobookID: audiobookID, epubURL: epubURL)

        // 2. Prepare asset storage directory (for image localization below).
        try assetStorage.prepare(for: audiobookID)

        var allBlocks = parse.blocks

        // 3. Rebuild the per-spine lookups for resolving TOC entries to blocks:
        // fragment anchor → block id, plus first-heading / first-block
        // fallbacks for entries that point at whole files. Descriptors are
        // aligned 1:1 with blocks; kinds here are pre-TOC-promotion, matching
        // the original ordering.
        var anchorBlockIDBySpine: [Int: [String: String]] = [:]
        var firstHeadingBlockIDBySpine: [Int: String] = [:]
        var firstBlockIDBySpine: [Int: String] = [:]
        for (block, descriptor) in zip(parse.blocks, parse.descriptors) {
            let i = block.spineIndex
            if firstBlockIDBySpine[i] == nil { firstBlockIDBySpine[i] = block.id }
            if firstHeadingBlockIDBySpine[i] == nil,
                block.blockKind == EPubBlockRecord.Kind.heading.rawValue
            {
                firstHeadingBlockIDBySpine[i] = block.id
            }
            for anchor in descriptor.anchorIDs where anchorBlockIDBySpine[i]?[anchor] == nil {
                anchorBlockIDBySpine[i, default: [:]][anchor] = block.id
            }
        }

        // 4. Copy images referenced in blocks to local asset storage.
        for idx in allBlocks.indices {
            guard allBlocks[idx].blockKind == EPubBlockRecord.Kind.image.rawValue,
                let imagePath = allBlocks[idx].imagePath
            else { continue }
            let xhtmlURL = parse.spineXHTMLURLByIndex[allBlocks[idx].spineIndex] ?? epubURL
            let sourceURL = resolveImageURL(
                href: imagePath, baseURL: xhtmlURL.deletingLastPathComponent(),
                epubRoot: epubURL, opfDir: parse.opfDir)
            if let localPath = assetStorage.copyImage(
                from: sourceURL, audiobookID: audiobookID,
                filename: URL(fileURLWithPath: imagePath).lastPathComponent)
            {
                allBlocks[idx].imagePath = localPath
            }
        }

        // 5. Resolve the publisher's TOC tree (NCX navPoint / nav ol nesting)
        // to concrete blocks, promoting fragment targets that aren't marked up
        // as headings (table-styled topic titles) so the reader can style and
        // anchor them. Runs before chapter-index assignment so promotions
        // count as headings there.
        let tocRecords = Self.resolveTOCEntries(
            parse.tocEntryTree,
            audiobookID: audiobookID,
            spine: parse.spine,
            anchorBlockIDBySpine: anchorBlockIDBySpine,
            firstHeadingBlockIDBySpine: firstHeadingBlockIDBySpine,
            firstBlockIDBySpine: firstBlockIDBySpine,
            blocks: &allBlocks
        )

        // 7. Assign Chapter Index based on cumulative word-count fraction.
        if let duration = bookDuration, !chapters.isEmpty, !allBlocks.isEmpty {
            let totalWords = Double(allBlocks.reduce(0) { $0 + ($1.wordCount ?? 1) })
            if totalWords > 0 {
                var cumulativeWords = 0
                var hasSeenFirstHeading = false
                for i in 0..<allBlocks.count {
                    if allBlocks[i].blockKind == EPubBlockRecord.Kind.heading.rawValue {
                        hasSeenFirstHeading = true
                    }
                    cumulativeWords += allBlocks[i].wordCount ?? 1
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
                let totalBlocks = Double(allBlocks.count)
                for i in 0..<allBlocks.count {
                    let estimatedFraction = Double(allBlocks[i].sequenceIndex) / totalBlocks
                    let estimatedTime = estimatedFraction * duration
                    if let matchedChapter = chapters.first(where: { ch in
                        estimatedTime >= ch.startSeconds && estimatedTime < ch.endSeconds
                    }) {
                        allBlocks[i].chapterIndex = matchedChapter.index
                    }
                }
            }
        }

        // 8. Write blocks to database.
        guard let db = assetStorage.databaseService else {
            throw EPUBImportError.databaseNotAvailable
        }
        let dao = EPubBlockDAO(db: db.writer)
        try dao.deleteAll(for: audiobookID)
        try dao.insertAll(allBlocks)

        let tocDAO = EPubTOCEntryDAO(db: db.writer)
        try tocDAO.deleteAll(for: audiobookID)
        try tocDAO.insertAll(tocRecords)

        logger.info(
            "Imported \(allBlocks.count) EPUB blocks and \(tocRecords.count) TOC entries for \(audiobookID)"
        )
        return allBlocks
    }

    // MARK: - TOC entry resolution

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
    ) -> [EPubTOCEntryRecord] {
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

        func appendEntries(_ nodes: [TOCEntryNode], parentID: String?, depth: Int) {
            for node in nodes {
                guard let spineIdx = resolveSpineIndex(node.href) else {
                    appendEntries(node.children, parentID: parentID, depth: depth)
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
                    promoteToHeadingIfTitleMatches(
                        &blocks[arrayIdx], title: node.title, depth: depth)
                }

                appendEntries(node.children, parentID: entryID, depth: depth + 1)
            }
        }
        appendEntries(tree, parentID: nil, depth: 0)
        return records
    }

    /// Promotes a fragment-resolved paragraph to a heading when its text is
    /// essentially the TOC entry's title. Publishers mark some section titles
    /// up as layout tables (The Pragmatic Programmer's "Topic N" recipes), so
    /// they never arrive as `<h1>`–`<h6>`. The title-similarity gate keeps
    /// body prose safe when an entry anchors at a regular paragraph.
    private static func promoteToHeadingIfTitleMatches(
        _ block: inout EPubBlockRecord, title: String, depth: Int
    ) {
        guard block.blockKind == EPubBlockRecord.Kind.paragraph.rawValue,
            let text = block.text, !text.isEmpty, text.count <= 120,
            titlesEssentiallyMatch(text, title)
        else { return }

        block.blockKind = EPubBlockRecord.Kind.heading.rawValue
        let level = min(max(depth + 1, 1), 6)
        var markers = block.decodedMarkers
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
