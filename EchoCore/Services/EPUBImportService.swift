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
                    rawTags: textBlocks[j].rawTags
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

        logger.info("Imported \(allBlocks.count) EPUB blocks for \(audiobookID)")
        return allBlocks
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
