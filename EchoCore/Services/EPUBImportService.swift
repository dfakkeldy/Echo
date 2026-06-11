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
        // 1. Locate container.xml and find the OPF path.
        let containerURL = epubURL.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw EPUBImportError.notAnEPUB(url: epubURL)
        }

        let containerData = try Data(contentsOf: containerURL)
        guard let opfRelativePath = parseContainerXML(from: containerData) else {
            throw EPUBImportError.missingOPF
        }
        let opfURL = epubURL.appendingPathComponent(opfRelativePath)
        let opfDir = opfURL.deletingLastPathComponent()

        // 2. Parse OPF for spine order.
        let opfData = try Data(contentsOf: opfURL)
        let opfResult = parseOPF(from: opfData)
        let spine = opfResult.spine
        guard !spine.isEmpty else {
            throw EPUBImportError.spineEmpty
        }

        // 2.5 Parse TOC (and EPUB 3 landmarks) if available
        var tocMap: [String: String] = [:]
        var tocEntryTree: [TOCEntryNode] = []
        var landmarks: [GuideReference] = []
        if let tocHref = opfResult.tocHref {
            let tocURL: URL
            if tocHref.hasPrefix("/") || tocHref.contains("://") {
                tocURL = epubURL.appendingPathComponent(tocHref)
            } else {
                tocURL = opfDir.appendingPathComponent(tocHref)
            }
            if let tocData = try? Data(contentsOf: tocURL) {
                let tocParser = TOCParserDelegate()
                tocParser.parse(tocData)
                tocMap = tocParser.tocMap
                tocEntryTree = tocParser.tocEntries
                landmarks = tocParser.landmarks
            }
        }

        // 2.6 Locate where body matter starts so front matter (cover, praise
        // pages, printed TOC, …) is never promoted to chapters.
        let bodyStartSpineIndex = Self.bodyMatterStartIndex(
            spine: spine,
            guideReferences: opfResult.guideReferences,
            landmarks: landmarks
        )

        // 3. Prepare asset storage directory.
        try assetStorage.prepare(for: audiobookID)

        // 4. Parse XHTML spine items into blocks.
        var parsedSpines: [(blocks: [TextBlockDescriptor], title: String?, url: URL)] = []

        for (_, item) in spine.enumerated() {
            let href = item.href
            let xhtmlURL: URL
            if href.hasPrefix("/") || href.contains("://") {
                xhtmlURL = epubURL.appendingPathComponent(href)
            } else {
                xhtmlURL = opfDir.appendingPathComponent(href)
            }

            guard FileManager.default.fileExists(atPath: xhtmlURL.path) else {
                logger.warning("Spine item not found: \(href)")
                parsedSpines.append((blocks: [], title: nil, url: xhtmlURL))
                continue
            }

            let xhtmlData = try Data(contentsOf: xhtmlURL)
            let parsedXHTML = parseXHTML(from: xhtmlData)
            parsedSpines.append((blocks: parsedXHTML.blocks, title: parsedXHTML.title, url: xhtmlURL))
        }

        // 5. Apply Heuristic Engine
        var engine = EPUBHeuristicEngine(tocLabels: Array(tocMap.values), spineItemCount: spine.count)
        let allExtractedBlocks = parsedSpines.flatMap { $0.blocks }
        engine.buildCSSFingerprint(from: allExtractedBlocks)
        
        var allBlocks: [EPubBlockRecord] = []
        var sequenceIndex = 0
        var hasSeenContentHeading = false

        // Per-spine lookups for resolving TOC entries to blocks:
        // fragment anchor → block id, plus first-heading / first-block
        // fallbacks for entries that point at whole files.
        var anchorBlockIDBySpine: [Int: [String: String]] = [:]
        var firstHeadingBlockIDBySpine: [Int: String] = [:]
        var firstBlockIDBySpine: [Int: String] = [:]

        for i in 0..<parsedSpines.count {
            var textBlocks = parsedSpines[i].blocks
            let spineHref = spine[i].href
            
            // Score pass
            for j in 0..<textBlocks.count {
                let newKind = engine.score(block: textBlocks[j])
                // Create a new struct to update the kind
                textBlocks[j] = TextBlockDescriptor(
                    kind: newKind,
                    text: textBlocks[j].text,
                    imagePath: textBlocks[j].imagePath,
                    htmlContent: textBlocks[j].htmlContent,
                    markers: textBlocks[j].markers,
                    textFormats: textBlocks[j].textFormats,
                    rawClasses: textBlocks[j].rawClasses,
                    rawTags: textBlocks[j].rawTags,
                    anchorIDs: textBlocks[j].anchorIDs
                )
            }
            
            // Apply TOC Map or Document Title fallback if no *content* heading.
            let hasContentHeading = textBlocks.contains(where: { block in
                guard block.kind == .heading,
                      let text = block.text,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty
                else { return false }
                return !HeadingClassifier.isJunk(text)
            })

            let decodedHref = spineHref.removingPercentEncoding ?? spineHref
            let hrefWithoutFragment = String(decodedHref.components(separatedBy: "#")[0])
            let fallbackTitle = tocMap[hrefWithoutFragment] ?? parsedSpines[i].title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleIsNonContent = fallbackTitle.map(HeadingClassifier.isNonContent) ?? false

            // Front matter by structure (linear="no", or before the guide /
            // landmarks body start), or — when the EPUB provides no structural
            // info — by a non-content title on a heading-less spine before any
            // real content has appeared.
            let structuralFrontMatter = !spine[i].linear
                || (bodyStartSpineIndex.map { i < $0 } ?? false)
            let isFrontMatterSpine = structuralFrontMatter
                || (!hasContentHeading && titleIsNonContent && !hasSeenContentHeading)

            if hasContentHeading {
                hasSeenContentHeading = true
            } else if !isFrontMatterSpine, !titleIsNonContent,
                      let title = fallbackTitle, !title.isEmpty,
                      title.lowercased() != "untitled", title.lowercased() != "unknown" {
                let headingBlock = TextBlockDescriptor(
                    kind: .heading,
                    text: title,
                    imagePath: nil,
                    htmlContent: "<h2>\(title)</h2>",
                    markers: [SyncMarker(type: .chapterStart, payload: "1", epubCharOffset: 0)],
                    textFormats: []
                )
                textBlocks.insert(headingBlock, at: 0)
            }

            var spineRecords: [EPubBlockRecord] = []
            for (blockIdx, textBlock) in textBlocks.enumerated() {
                let wordCount = textBlock.text?.split(whereSeparator: { $0.isWhitespace }).count ?? 0
                let block = EPubBlockRecord(
                    id: "epub-\(audiobookID)-s\(i)-b\(blockIdx)",
                    audiobookID: audiobookID,
                    spineHref: spineHref,
                    spineIndex: i,
                    blockIndex: blockIdx,
                    sequenceIndex: sequenceIndex,
                    blockKind: textBlock.kind.rawValue,
                    text: textBlock.text,
                    htmlContent: textBlock.htmlContent,
                    cardColor: nil,
                    imagePath: textBlock.imagePath,
                    chapterIndex: nil,
                    isHidden: false,
                    hiddenReason: nil,
                    isFrontMatter: isFrontMatterSpine,
                    wordCount: max(1, wordCount),
                    markers: EPubBlockRecord.encodeMarkers(textBlock.markers),
                    textFormats: EPubBlockRecord.encodeFormats(textBlock.textFormats),
                    createdAt: AlignmentService.isoFormatter.string(from: Date()),
                    modifiedAt: nil
                )
                spineRecords.append(block)
                sequenceIndex += 1
            }

            // Record TOC-resolution lookups (descriptors and records align by index).
            firstBlockIDBySpine[i] = spineRecords.first?.id
            for (descriptor, record) in zip(textBlocks, spineRecords) {
                if firstHeadingBlockIDBySpine[i] == nil,
                   record.blockKind == EPubBlockRecord.Kind.heading.rawValue {
                    firstHeadingBlockIDBySpine[i] = record.id
                }
                for anchor in descriptor.anchorIDs where anchorBlockIDBySpine[i]?[anchor] == nil {
                    anchorBlockIDBySpine[i, default: [:]][anchor] = record.id
                }
            }

            // 6. Copy images referenced in blocks to local asset storage.
            let xhtmlURL = parsedSpines[i].url
            for var block in spineRecords {
                if block.blockKind == EPubBlockRecord.Kind.image.rawValue,
                   let imagePath = block.imagePath {
                    let sourceURL = resolveImageURL(href: imagePath, baseURL: xhtmlURL.deletingLastPathComponent(), epubRoot: epubURL, opfDir: opfDir)
                    if let localPath = assetStorage.copyImage(from: sourceURL, audiobookID: audiobookID, filename: URL(fileURLWithPath: imagePath).lastPathComponent) {
                        block.imagePath = localPath
                    }
                }
                allBlocks.append(block)
            }
        }
        
        // 6.5 Resolve the publisher's TOC tree (NCX navPoint / nav ol nesting)
        // to concrete blocks, promoting fragment targets that aren't marked up
        // as headings (table-styled topic titles) so the reader can style and
        // anchor them. Runs before chapter-index assignment so promotions
        // count as headings there.
        let tocRecords = Self.resolveTOCEntries(
            tocEntryTree,
            audiobookID: audiobookID,
            spine: spine,
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
                           estimatedFraction < 0.25 {
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

        logger.info("Imported \(allBlocks.count) EPUB blocks and \(tocRecords.count) TOC entries for \(audiobookID)")
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
            let normalized = normalizeHref(item.href)
            if spineIndexByHref[normalized] == nil { spineIndexByHref[normalized] = idx }
            let filename = URL(fileURLWithPath: normalized).lastPathComponent
            if spineIndexByFilename[filename] == nil { spineIndexByFilename[filename] = idx }
        }

        var blockArrayIndexByID: [String: Int] = [:]
        for (idx, block) in blocks.enumerated() { blockArrayIndexByID[block.id] = idx }

        var records: [EPubTOCEntryRecord] = []
        var orderCounter = 0

        func resolveSpineIndex(_ href: String) -> Int? {
            let normalized = normalizeHref(href)
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
                   let anchorHit = anchorBlockIDBySpine[spineIdx]?[fragment] {
                    resolvedBlockID = anchorHit
                    fragmentResolved = true
                } else {
                    resolvedBlockID = firstHeadingBlockIDBySpine[spineIdx] ?? firstBlockIDBySpine[spineIdx]
                }

                let entryID = "toc-\(audiobookID)-\(orderCounter)"
                records.append(EPubTOCEntryRecord(
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
                   let arrayIdx = blockArrayIndexByID[blockID] {
                    promoteToHeadingIfTitleMatches(&blocks[arrayIdx], title: node.title, depth: depth)
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

    // MARK: - Front matter classification

    /// Spine index where body matter starts, from EPUB 3 landmarks
    /// (`epub:type="bodymatter"`) or the EPUB 2 guide (`type="text"`).
    /// Returns nil when the EPUB provides neither signal.
    static func bodyMatterStartIndex(
        spine: [SpineItemDescriptor],
        guideReferences: [GuideReference],
        landmarks: [GuideReference]
    ) -> Int? {
        let candidates = landmarks.filter { $0.type.split(separator: " ").contains("bodymatter") }
            + guideReferences.filter { $0.type == "text" }
        for candidate in candidates {
            if let index = spineIndex(of: candidate.href, in: spine) {
                return index
            }
        }
        return nil
    }

    private static func spineIndex(of href: String, in spine: [SpineItemDescriptor]) -> Int? {
        let target = normalizeHref(href)
        if let exact = spine.firstIndex(where: { normalizeHref($0.href) == target }) {
            return exact
        }
        // Guide/landmark hrefs can be relative to a different directory than
        // spine hrefs (nav doc vs OPF); fall back to filename equality.
        let targetName = URL(fileURLWithPath: target).lastPathComponent
        return spine.firstIndex(where: {
            URL(fileURLWithPath: normalizeHref($0.href)).lastPathComponent == targetName
        })
    }

    private static func normalizeHref(_ href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        return String(decoded.components(separatedBy: "#")[0])
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

// MARK: - Errors

enum EPUBImportError: LocalizedError, Equatable {
    case notAnEPUB(url: URL)
    case missingOPF
    case spineEmpty
    case databaseNotAvailable

    var errorDescription: String? {
        switch self {
        case .notAnEPUB(let url):
            return "Not a valid EPUB: \(url.lastPathComponent)"
        case .missingOPF:
            return "container.xml does not reference a content.opf"
        case .spineEmpty:
            return "EPUB spine is empty — no content to import"
        case .databaseNotAvailable:
            return "Database service not available for EPUB import"
        }
    }
}
