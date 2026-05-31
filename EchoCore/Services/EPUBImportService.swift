import Foundation
import os.log

/// Imports EPUB structure into the application's SQL database and local asset storage.
///
/// Responsibilities:
/// - Parse OPF spine order and XHTML content into ordered blocks
/// - Split text into paragraph-level blocks (sentence-level optional for later)
/// - Copy referenced images to app-controlled storage
/// - Write `epub_block` records to the database
/// - Post `timelineItemsIngested` notification to trigger feed reload
///
/// For V1, the EPUB is expected to be provided as an expanded directory.
/// ZIP extraction support requires the ZIPFoundation package.
struct EPUBImportService {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "EPUBImport")

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
        let spine = parseOPF(from: opfData)
        guard !spine.isEmpty else {
            throw EPUBImportError.spineEmpty
        }

        // 3. Prepare asset storage directory.
        try assetStorage.prepare(for: audiobookID)

        // 4. Parse XHTML spine items into blocks.
        var allBlocks: [EPubBlockRecord] = []
        var sequenceIndex = 0

        for (spineIdx, item) in spine.enumerated() {
            let href = item.href
            let xhtmlURL: URL
            if href.hasPrefix("/") || href.contains("://") {
                xhtmlURL = epubURL.appendingPathComponent(href)
            } else {
                xhtmlURL = opfDir.appendingPathComponent(href)
            }

            guard FileManager.default.fileExists(atPath: xhtmlURL.path) else {
                logger.warning("Spine item not found: \(href)")
                continue
            }

            let xhtmlData = try Data(contentsOf: xhtmlURL)
            let textBlocks = parseXHTML(from: xhtmlData)
            var blocks: [EPubBlockRecord] = []
            for (blockIdx, textBlock) in textBlocks.enumerated() {
                let wordCount = textBlock.text?.split(whereSeparator: { $0.isWhitespace }).count ?? 0
                let block = EPubBlockRecord(
                    id: "epub-\(audiobookID)-s\(spineIdx)-b\(blockIdx)",
                    audiobookID: audiobookID,
                    spineHref: href,
                    spineIndex: spineIdx,
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
                    wordCount: max(1, wordCount),
                    createdAt: AlignmentService.isoFormatter.string(from: Date()),
                    modifiedAt: nil
                )
                blocks.append(block)
                sequenceIndex += 1
            }

            // 5. Copy images referenced in blocks to local asset storage.
            for var block in blocks {
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
        
        // 4.5. Assign Chapter Index based on global sequence fraction.
        if let duration = bookDuration, !chapters.isEmpty, !allBlocks.isEmpty {
            let totalBlocks = Double(allBlocks.count)
            for i in 0..<allBlocks.count {
                let estimatedFraction = Double(allBlocks[i].sequenceIndex) / totalBlocks
                let estimatedTime = estimatedFraction * duration
                if let idx = chapters.firstIndex(where: { ch in
                    estimatedTime >= ch.startSeconds && estimatedTime < ch.endSeconds
                }) {
                    allBlocks[i].chapterIndex = idx
                }
            }
        }

        // 6. Write blocks to database.
        guard let db = assetStorage.databaseService else {
            throw EPUBImportError.databaseNotAvailable
        }
        let dao = EPubBlockDAO(db: db.writer)
        try dao.deleteAll(for: audiobookID)
        try dao.insertAll(allBlocks)

        logger.info("Imported \(allBlocks.count) EPUB blocks for \(audiobookID)")
        return allBlocks
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

