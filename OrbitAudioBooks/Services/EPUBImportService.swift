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

        let opfRelativePath = try parseContainerXML(at: containerURL)
        let opfURL = epubURL.appendingPathComponent(opfRelativePath)
        let opfDir = opfURL.deletingLastPathComponent()

        // 2. Parse OPF for spine order.
        let spine = try parseOPF(at: opfURL)

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
            let blocks = try parseXHTML(
                data: xhtmlData,
                baseURL: xhtmlURL.deletingLastPathComponent(),
                audiobookID: audiobookID,
                spineHref: href,
                spineIndex: spineIdx,
                startingSequence: &sequenceIndex,
                chapters: chapters,
                bookDuration: bookDuration
            )

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

    // MARK: - Container XML

    private func parseContainerXML(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let parser = ContainerXMLParser()
        parser.parse(data)
        guard let path = parser.rootfilePath else {
            throw EPUBImportError.missingOPF
        }
        return path
    }

    // MARK: - OPF

    private func parseOPF(at url: URL) throws -> [SpineItemDescriptor] {
        let data = try Data(contentsOf: url)
        let parser = OPFParserDelegate()
        parser.parse(data)
        guard !parser.spineItems.isEmpty else {
            throw EPUBImportError.spineEmpty
        }
        return parser.spineItems
    }

    // MARK: - XHTML

    private func parseXHTML(
        data: Data,
        baseURL: URL,
        audiobookID: String,
        spineHref: String,
        spineIndex: Int,
        startingSequence: inout Int,
        chapters: [Chapter],
        bookDuration: TimeInterval?
    ) throws -> [EPubBlockRecord] {
        let parser = XHTMLBlockDelegate()
        parser.parse(data)

        var blocks: [EPubBlockRecord] = []

        // Chapter index assignment: match block position to closest chapter by
        // estimated timestamp (if available), otherwise sequential.
        var chapterIndex: Int?
        if let duration = bookDuration, !chapters.isEmpty {
            let estimatedFraction = Double(startingSequence) / Double(max(1, parser.textBlocks.count))
            let estimatedTime = estimatedFraction * duration
            chapterIndex = chapters.firstIndex { ch in
                estimatedTime >= ch.startSeconds && estimatedTime < ch.endSeconds
            }
        }

        for (blockIdx, textBlock) in parser.textBlocks.enumerated() {
            let block = EPubBlockRecord(
                id: "epub-\(audiobookID)-s\(spineIndex)-b\(blockIdx)",
                audiobookID: audiobookID,
                spineHref: spineHref,
                spineIndex: spineIndex,
                blockIndex: blockIdx,
                sequenceIndex: startingSequence,
                blockKind: textBlock.kind.rawValue,
                text: textBlock.text,
                imagePath: textBlock.imagePath,
                chapterIndex: chapterIndex,
                isHidden: false,
                hiddenReason: nil,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                modifiedAt: nil
            )
            blocks.append(block)
            startingSequence += 1
        }

        return blocks
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

// MARK: - Models

struct SpineItemDescriptor {
    let id: String
    let href: String
    let mediaType: String
}

struct TextBlockDescriptor {
    let kind: EPubBlockRecord.Kind
    let text: String?
    let imagePath: String?
}

// MARK: - XML Parser Delegates

private final class ContainerXMLParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile", let path = attributeDict["full-path"] {
            rootfilePath = path
        }
    }
}

private final class OPFParserDelegate: NSObject, XMLParserDelegate {
    var spineItems: [SpineItemDescriptor] = []
    private var manifestItems: [String: SpineItemDescriptor] = [:]
    private var spineIDRefs: [String] = []
    private var currentAttributes: [String: String] = [:]

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentAttributes = attributeDict
        if elementName == "itemref", let idref = attributeDict["idref"] {
            spineIDRefs.append(idref)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item",
           let id = currentAttributes["id"],
           let href = currentAttributes["href"],
           let mediaType = currentAttributes["media-type"] {
            manifestItems[id] = SpineItemDescriptor(id: id, href: href, mediaType: mediaType)
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        spineItems = spineIDRefs.compactMap { manifestItems[$0] }
    }
}

private final class XHTMLBlockDelegate: NSObject, XMLParserDelegate {
    var textBlocks: [TextBlockDescriptor] = []
    private var currentText = ""
    private var currentHeading = ""
    private var isInHeading = false
    private var skipDepth = 0
    private var pendingImagePath: String?
    private let skipTags: Set<String> = ["script", "style", "head"]
    private let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li", "section"]

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        flushBlock()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if skipTags.contains(elementName) { skipDepth += 1; return }
        guard skipDepth == 0 else { return }

        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
            isInHeading = true
            currentHeading = ""
        } else if elementName == "img", let src = attributeDict["src"] {
            flushBlock()
            textBlocks.append(TextBlockDescriptor(
                kind: .image,
                text: attributeDict["alt"],
                imagePath: src
            ))
        } else if blockTags.contains(elementName) {
            flushBlock()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isInHeading { currentHeading += trimmed + " " }
        if !trimmed.isEmpty { currentText += trimmed + " " }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if skipTags.contains(elementName) { skipDepth = max(0, skipDepth - 1); return }
        guard skipDepth == 0 else { return }

        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
            isInHeading = false
            let heading = currentHeading.trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty {
                textBlocks.append(TextBlockDescriptor(
                    kind: .heading,
                    text: heading,
                    imagePath: nil
                ))
            }
        }
    }

    private func flushBlock() {
        let text = currentText.trimmingCharacters(in: .whitespaces)
        currentText = ""
        guard !text.isEmpty else { return }
        textBlocks.append(TextBlockDescriptor(
            kind: .paragraph,
            text: text,
            imagePath: nil
        ))
    }
}
