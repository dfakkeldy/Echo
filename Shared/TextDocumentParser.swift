// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TextParseError: Error { case unreadable(URL) }

/// An intermediate, format-neutral unit produced by tokenizing a text document.
private enum TextUnit {
    case heading(level: Int, text: String)
    case paragraph(String)
}

/// Decides the chapter break level for a document's heading depths.
enum TextDocChapterLeveling {
    /// The heading depth (1–6) at which chapters break.
    ///
    /// 1. The shallowest depth that occurs at least twice — the clearest signal
    ///    that "these are the chapters" (a lone `#` title above repeated `##`
    ///    chapters does not count, so `##` wins).
    /// 2. When nothing repeats: a lone leading `#` (H1) is treated as a book
    ///    title, so chapters are the next level down. Any other lone shallowest
    ///    heading (e.g. a single `##` with a `###` section) is itself the chapter.
    /// 3. `nil` when there are no headings at all (one body chapter).
    static func chapterLevel(of levels: [Int]) -> Int? {
        guard !levels.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for l in levels { counts[l, default: 0] += 1 }
        if let shallowestRepeating = counts.filter({ $0.value >= 2 }).keys.min() {
            return shallowestRepeating
        }
        let present = counts.keys.sorted()
        // A lone leading H1 above deeper headings is a title → skip it.
        if present.count >= 2, present[0] == 1, counts[1] == 1 {
            return present[1]
        }
        return present[0]
    }
}

// MARK: - Public entry points

/// Parses a Markdown file into the canonical block set (chapters follow the
/// heading hierarchy). Drop-in for `EPUBImportService.import(parse:)`.
func parseMarkdownBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
        throw TextParseError.unreadable(fileURL)
    }
    return parseMarkdown(audiobookID: audiobookID, content: content, sourceURL: fileURL)
}

func parseMarkdown(audiobookID: String, content: String, sourceURL: URL) -> EPUBBlockParse {
    let units = tokenizeMarkdown(content)
    return buildParse(
        units: units, audiobookID: audiobookID, sourceURL: sourceURL, hrefExt: "md")
}

// MARK: - Markdown tokenizer

private func tokenizeMarkdown(_ content: String) -> [TextUnit] {
    var units: [TextUnit] = []
    var paragraphLines: [String] = []
    var inFence = false

    func flushParagraph() {
        let joined = paragraphLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { units.append(.paragraph(joined)) }
        paragraphLines.removeAll()
    }

    for rawLine in content.components(separatedBy: .newlines) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            if inFence {
                inFence = false
            } else {
                flushParagraph()
                inFence = true
            }
            continue
        }
        if inFence { continue }
        if trimmed.isEmpty {
            flushParagraph()
            continue
        }
        if isMarkdownThematicBreak(trimmed) {
            flushParagraph()
            continue
        }

        if let heading = parseHeading(trimmed) {
            flushParagraph()
            units.append(.heading(level: heading.level, text: heading.text))
            continue
        }
        if trimmed.hasPrefix("|") { continue }  // table row
        if trimmed.hasPrefix("![") { continue }  // standalone image

        if let item = parseListItem(trimmed) {
            flushParagraph()
            units.append(.paragraph(item))
            continue
        }
        if trimmed.hasPrefix(">") {
            let text = String(trimmed.drop(while: { $0 == ">" || $0 == " " }))
            if !text.isEmpty { paragraphLines.append(text) }
            continue
        }
        paragraphLines.append(trimmed)
    }
    flushParagraph()
    return units
}

private func isMarkdownThematicBreak(_ line: String) -> Bool {
    let marks = line.filter { !$0.isWhitespace }
    guard marks.count >= 3, let first = marks.first else { return false }
    guard first == "-" || first == "*" || first == "_" else { return false }
    return marks.allSatisfy { $0 == first }
}

/// `^(#{1,6})\s+(.*)$` → (level, trimmed title), else nil.
private func parseHeading(_ line: String) -> (level: Int, text: String)? {
    var level = 0
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == "#", level < 6 {
        level += 1
        idx = line.index(after: idx)
    }
    guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
    let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (level, text)
}

/// `^([-*+]|\d+\.)\s+(.*)$` → item text, else nil.
private func parseListItem(_ line: String) -> String? {
    let scalars = Array(line)
    if let first = scalars.first, "-*+".contains(first),
        scalars.count > 1, scalars[1] == " "
    {
        return String(scalars.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    // ordered: digits then "." then space
    var i = 0
    while i < scalars.count, scalars[i].isNumber { i += 1 }
    if i > 0, i + 1 < scalars.count, scalars[i] == ".", scalars[i + 1] == " " {
        return String(scalars[(i + 2)...]).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

// MARK: - Block assembly

private func buildParse(
    units: [TextUnit], audiobookID: String, sourceURL: URL, hrefExt: String
) -> EPUBBlockParse {
    let levels: [Int] = units.compactMap {
        if case .heading(let l, _) = $0 { return l } else { return nil }
    }
    let chapterLevel = TextDocChapterLeveling.chapterLevel(of: levels)

    var blocks: [EPubBlockRecord] = []
    var descriptors: [TextBlockDescriptor] = []
    var spineIndexesUsed: [Int] = []

    var spineIndex = 0
    var blockIndex = 0
    var sequenceIndex = 0
    var seenChapterHeading = false
    var emittedFrontMatter = false
    let createdAt = ISO8601DateFormatter().string(from: Date())

    func spineHref(_ i: Int) -> String { "text-s\(i).\(hrefExt)" }

    @discardableResult
    func emit(
        kind: EPubBlockRecord.Kind, plain: String, formats: [TextFormat],
        isFrontMatter: Bool, headingLevel: Int?
    ) -> String? {
        if spineIndexesUsed.last != spineIndex { spineIndexesUsed.append(spineIndex) }
        let anchorID = (kind == .heading) ? "b\(spineIndex)-\(blockIndex)" : nil
        var markers: [SyncMarker] = []
        if let level = headingLevel {
            markers.append(
                SyncMarker(type: .chapterStart, payload: String(level), epubCharOffset: 0))
        }
        let wordCount = max(1, plain.split(whereSeparator: { $0.isWhitespace }).count)

        blocks.append(
            EPubBlockRecord(
                id: "epub-\(audiobookID)-s\(spineIndex)-b\(blockIndex)",
                audiobookID: audiobookID,
                spineHref: spineHref(spineIndex),
                spineIndex: spineIndex,
                blockIndex: blockIndex,
                sequenceIndex: sequenceIndex,
                blockKind: kind.rawValue,
                text: plain,
                htmlContent: nil,
                cardColor: nil,
                imagePath: nil,
                chapterIndex: nil,
                isHidden: false,
                hiddenReason: nil,
                isFrontMatter: isFrontMatter,
                wordCount: wordCount,
                markers: EPubBlockRecord.encodeMarkers(markers),
                textFormats: EPubBlockRecord.encodeFormats(formats),
                createdAt: createdAt,
                modifiedAt: nil))

        descriptors.append(
            TextBlockDescriptor(
                kind: kind, text: plain, imagePath: nil, htmlContent: nil,
                markers: markers, textFormats: formats,
                anchorIDs: anchorID.map { [$0] } ?? []))

        blockIndex += 1
        sequenceIndex += 1
        return anchorID
    }

    func startNewSpine() {
        spineIndex += 1
        blockIndex = 0
    }

    var tocTree: [TOCEntryNode] = []
    var currentChapterTOCIndex: Int? = nil  // chapter node a section nests under

    for unit in units {
        switch unit {
        case .heading(let level, let rawText):
            let (plain, formats) = MarkdownInlineFormatter.format(rawText)
            if let chapterLevel, level == chapterLevel {
                if !seenChapterHeading {
                    if emittedFrontMatter { startNewSpine() }
                    seenChapterHeading = true
                } else {
                    startNewSpine()
                }
                let usedAnchor = emit(
                    kind: .heading, plain: plain, formats: formats,
                    isFrontMatter: false, headingLevel: level)
                tocTree.append(
                    TOCEntryNode(
                        title: plain, href: spineHref(spineIndex), fragment: usedAnchor,
                        children: []))
                currentChapterTOCIndex = tocTree.count - 1
            } else {
                // Shallower lone title, or deeper section heading.
                let front = !seenChapterHeading
                if front { emittedFrontMatter = true }
                let usedAnchor = emit(
                    kind: .heading, plain: plain, formats: formats,
                    isFrontMatter: front, headingLevel: level)
                if !front, let chapterIdx = currentChapterTOCIndex {
                    tocTree[chapterIdx].children.append(
                        TOCEntryNode(
                            title: plain, href: spineHref(spineIndex), fragment: usedAnchor,
                            children: []))
                }
            }
        case .paragraph(let rawText):
            let (plain, formats) = MarkdownInlineFormatter.format(rawText)
            let front = (chapterLevel != nil) && !seenChapterHeading
            if front { emittedFrontMatter = true }
            emit(
                kind: .paragraph, plain: plain, formats: formats,
                isFrontMatter: front, headingLevel: nil)
        }
    }

    let spine = spineIndexesUsed.map {
        SpineItemDescriptor(
            id: spineHref($0), href: spineHref($0), mediaType: "text/markdown", linear: true)
    }
    var spineXHTMLURLByIndex: [Int: URL] = [:]
    for i in spineIndexesUsed { spineXHTMLURLByIndex[i] = sourceURL }

    return EPUBBlockParse(
        blocks: blocks,
        descriptors: descriptors,
        spine: spine,
        tocEntryTree: tocTree,
        opfDir: sourceURL.deletingLastPathComponent(),
        spineXHTMLURLByIndex: spineXHTMLURLByIndex)
}

// MARK: - Plain-text entry points

func parsePlainTextBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
        throw TextParseError.unreadable(fileURL)
    }
    return parsePlainText(audiobookID: audiobookID, content: content, sourceURL: fileURL)
}

func parsePlainText(audiobookID: String, content: String, sourceURL: URL) -> EPUBBlockParse {
    let units = tokenizePlainText(content)
    return buildParse(
        units: units, audiobookID: audiobookID, sourceURL: sourceURL, hrefExt: "txt")
}

/// Parses extracted PDF page text into one synthetic chapter per page. This is
/// used only when the plain-text pass cannot find useful chapter markers, so
/// large PDFs do not become one enormous narration batch.
func parsePDFPagesAsPlainTextChapters(
    audiobookID: String,
    pages: [String],
    sourceURL: URL
) -> EPUBBlockParse {
    var units: [TextUnit] = []
    for (index, page) in pages.enumerated() {
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        units.append(.heading(level: 1, text: "Page \(index + 1)"))
        units.append(contentsOf: tokenizePlainText(trimmed, recognizesChapterMarkers: false))
    }
    return buildParse(
        units: units, audiobookID: audiobookID, sourceURL: sourceURL, hrefExt: "txt")
}

/// Plain text has no markup: split paragraphs on blank lines, and promote
/// chapter-like lines to level-1 headings (one heading level → flat chapters).
private func tokenizePlainText(
    _ content: String,
    recognizesChapterMarkers: Bool = true
) -> [TextUnit] {
    var units: [TextUnit] = []
    var paragraphLines: [String] = []

    func flush() {
        let joined = paragraphLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { units.append(.paragraph(joined)) }
        paragraphLines.removeAll()
    }

    for rawLine in content.components(separatedBy: .newlines) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flush()
            continue
        }
        if recognizesChapterMarkers, isChapterMarker(trimmed) {
            flush()
            units.append(.heading(level: 1, text: trimmed))
            continue
        }
        paragraphLines.append(trimmed)
    }
    flush()
    return units
}

/// A line that looks like a chapter break: "Chapter 7", "CHAPTER VII",
/// "Part Two", a bare number, or a short ALL-CAPS title.
private func isChapterMarker(_ line: String) -> Bool {
    let lower = line.lowercased()
    let words = line.split(whereSeparator: { $0.isWhitespace })

    // "chapter|part|book <number|roman>"
    if let first = words.first.map(String.init)?.lowercased(),
        ["chapter", "part", "book"].contains(first), words.count >= 2
    {
        return true
    }
    // bare number ("7", "12.")
    if line.allSatisfy({ $0.isNumber || $0 == "." }) && line.contains(where: \.isNumber) {
        return true
    }
    // ALL-CAPS heading: a multi-word caps line ("CHAPTER VII", "PART TWO"),
    // or a single long caps word ("PROLOGUE", "EPILOGUE") — but NOT a short
    // 2–5 letter acronym/interjection ("OK", "NB", "USA", "NOTE", "STOP").
    let hasLetters = line.contains(where: { $0.isLetter })
    let letterCount = line.filter(\.isLetter).count
    if hasLetters, words.count <= 6, line == line.uppercased(), lower != line,
        words.count >= 2 || letterCount >= 6
    {
        return true
    }
    return false
}
