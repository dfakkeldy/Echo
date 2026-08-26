// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ArticleBlockSanitizer {
    func sanitize(envelope: ArticleCaptureEnvelope) throws -> ArticleSnapshot {
        let xmlCompatibleXHTML = Self.xmlCompatibleReadabilityFragment(
            envelope.payload.contentXHTML)
        let xhtmlData = Data(xmlCompatibleXHTML.utf8)
        let metadata = ArticleMetadata(
            title: normalizedText(envelope.payload.title) ?? "Untitled article",
            author: normalizedText(envelope.payload.byline),
            siteName: normalizedText(envelope.payload.siteName),
            language: normalizedText(envelope.payload.language),
            publishedTime: normalizedText(envelope.payload.publishedTime))

        guard xhtmlData.count <= ArticleWorkshopLimits.maxContentXHTMLBytes else {
            let warnings: [ArticleSanitizationWarning] = [.contentXHTMLTooLarge, .noUsableText]
            return try snapshot(
                captureID: envelope.captureID,
                metadata: metadata,
                blocks: [],
                warnings: warnings,
                contentState: .captureFailed)
        }

        let delegate = ArticleXHTMLSanitizerDelegate(
            captureID: envelope.captureID,
            sourceURL: normalizedHTTPURL(envelope.payload.sourceURL, relativeTo: nil))
        let parser = XMLParser(data: xhtmlData)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        delegate.finish()

        if !parsed, !delegate.stoppedForLimit {
            delegate.addWarning(.parserFailure)
        }
        let blocks = delegate.blocks
        var warnings = delegate.warnings
        let hasReadableContent = blocks.contains { block in
            [block.text, block.caption].contains { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        if !hasReadableContent { append(.noUsableText, to: &warnings) }
        let contentState: ArticleContentState
        if !hasReadableContent {
            contentState = .captureFailed
        } else if warnings.isEmpty {
            contentState = .ready
        } else {
            contentState = .reviewSuggested
        }
        return try snapshot(
            captureID: envelope.captureID,
            metadata: metadata,
            blocks: blocks,
            warnings: warnings,
            contentState: contentState)
    }

    /// Readability returns an HTML fragment despite the `contentXHTML` field
    /// name. Preserve the fragment's bytes semantically while making the two
    /// HTML constructs that XMLParser cannot accept XML-compatible.
    private static func xmlCompatibleReadabilityFragment(_ html: String) -> String {
        let normalizedEntities = html.replacingOccurrences(of: "&nbsp;", with: "&#160;")
        let voidElements: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
            "param", "source", "track", "wbr",
        ]
        var output = ""
        output.reserveCapacity(normalizedEntities.utf8.count)
        var cursor = normalizedEntities.startIndex

        while cursor < normalizedEntities.endIndex {
            guard normalizedEntities[cursor] == "<" else {
                output.append(normalizedEntities[cursor])
                cursor = normalizedEntities.index(after: cursor)
                continue
            }

            let tagStart = cursor
            var tagEnd = normalizedEntities.index(after: cursor)
            var quote: Character?
            while tagEnd < normalizedEntities.endIndex {
                let character = normalizedEntities[tagEnd]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                tagEnd = normalizedEntities.index(after: tagEnd)
            }
            guard tagEnd < normalizedEntities.endIndex else {
                output.append(contentsOf: normalizedEntities[tagStart...])
                break
            }

            let afterOpen = normalizedEntities.index(after: tagStart)
            var nameStart = afterOpen
            while nameStart < tagEnd, normalizedEntities[nameStart].isWhitespace {
                nameStart = normalizedEntities.index(after: nameStart)
            }
            let isMarkupDeclaration = nameStart < tagEnd
                && ["/", "!", "?"].contains(normalizedEntities[nameStart])
            var nameEnd = nameStart
            while nameEnd < tagEnd {
                let character = normalizedEntities[nameEnd]
                guard character.isLetter || character.isNumber || character == ":" else { break }
                nameEnd = normalizedEntities.index(after: nameEnd)
            }
            let name = String(normalizedEntities[nameStart..<nameEnd]).lowercased()
            var contentEnd = tagEnd
            while contentEnd > tagStart {
                let previous = normalizedEntities.index(before: contentEnd)
                guard normalizedEntities[previous].isWhitespace else { break }
                contentEnd = previous
            }
            let alreadySelfClosing = contentEnd > tagStart
                && normalizedEntities[normalizedEntities.index(before: contentEnd)] == "/"

            output.append(contentsOf: normalizedEntities[tagStart..<tagEnd])
            if !isMarkupDeclaration, voidElements.contains(name), !alreadySelfClosing {
                output.append("/")
            }
            output.append(">")
            cursor = normalizedEntities.index(after: tagEnd)
        }
        return output
    }

    private func snapshot(
        captureID: UUID,
        metadata: ArticleMetadata,
        blocks: [ArticleBlock],
        warnings: [ArticleSanitizationWarning],
        contentState: ArticleContentState
    ) throws -> ArticleSnapshot {
        ArticleSnapshot(
            captureID: captureID,
            metadata: metadata,
            blocks: blocks,
            warnings: warnings,
            contentState: contentState,
            snapshotSHA256: try ArticleWorkshopDigest.snapshot(
                captureID: captureID,
                metadata: metadata,
                blocks: blocks,
                warnings: warnings,
                contentState: contentState))
    }
}

private nonisolated final class ArticleXHTMLSanitizerDelegate: NSObject, XMLParserDelegate {
    private struct ActiveBlock {
        let elementName: String
        let kind: ArticleBlockKind
        var text = ""
        var sourceURL: URL?
        var codeLanguage: String?
    }

    private struct FigureContext {
        var imageBlockIndex: Int?
        var caption = ""
    }

    private let captureID: UUID
    private let sourceURL: URL?
    private var activeBlock: ActiveBlock?
    private var skipDepth = 0
    private var elementCount = 0
    private var imageCount = 0
    private var figureContexts: [FigureContext] = []
    private var isInCaption = false
    private(set) var blocks: [ArticleBlock] = []
    private(set) var warnings: [ArticleSanitizationWarning] = []
    private(set) var stoppedForLimit = false

    private static let structuralElements: [String: ArticleBlockKind] = [
        "h1": .heading, "h2": .heading, "h3": .heading, "h4": .heading, "h5": .heading, "h6": .heading,
        "p": .paragraph, "li": .listItem, "blockquote": .quote, "pre": .code,
    ]
    private static let leafElements: Set<String> = ["img", "hr"]
    private static let transparentElements: Set<String> = [
        "article", "body", "html", "main", "section", "div", "header", "footer", "aside", "nav",
        "ul", "ol", "figure", "figcaption", "a", "span", "strong", "b", "em", "i", "u", "small",
        "sub", "sup", "br", "code", "uni-article-paragraph",
    ]
    private static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"

    init(captureID: UUID, sourceURL: URL?) {
        self.captureID = captureID
        self.sourceURL = sourceURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard !stoppedForLimit else { return }
        elementCount += 1
        guard elementCount <= ArticleWorkshopLimits.maxDOMElements else {
            stop(parser, warning: .elementLimitReached)
            return
        }

        let name = localName(elementName)
        if skipDepth > 0 {
            skipDepth += 1
            return
        }
        if shouldSkipPresentationFurniture(name: name, attributes: attributeDict) {
            skipDepth = 1
            return
        }
        guard isAllowedElement(name, namespaceURI: namespaceURI) else {
            skipDepth = 1
            return
        }

        if name == "figure" {
            figureContexts.append(FigureContext())
            return
        }
        if name == "figcaption", !figureContexts.isEmpty {
            flushActiveBlock(parser)
            isInCaption = true
            return
        }
        if name == "br" {
            if isInCaption, !figureContexts.isEmpty {
                appendCollapsed(" ", to: &figureContexts[figureContexts.count - 1].caption)
            } else if var block = activeBlock {
                if block.kind == .code {
                    block.text += "\n"
                } else {
                    appendCollapsed(" ", to: &block.text)
                }
                activeBlock = block
            }
            return
        }
        if isInCaption { return }

        if name == "img" {
            flushActiveBlock(parser)
            guard let candidate = preferredImageURL(attributes: attributeDict) else {
                addWarning(.rejectedURLScheme)
                return
            }
            guard imageCount < ArticleWorkshopLimits.maxImages else {
                stop(parser, warning: .imageCandidateLimitReached)
                return
            }
            guard blocks.count < ArticleWorkshopLimits.maxBlocks else {
                stop(parser, warning: .blockLimitReached)
                return
            }
            appendBlock(
                kind: .image,
                text: nil,
                sourceURL: nil,
                imageCandidateURL: candidate,
                altText: normalizedText(attributeDict["alt"]),
                caption: nil,
                codeLanguage: nil,
                parser: parser)
            imageCount += 1
            if !figureContexts.isEmpty { figureContexts[figureContexts.count - 1].imageBlockIndex = blocks.count - 1 }
            return
        }
        if name == "hr" {
            flushActiveBlock(parser)
            appendBlock(
                kind: .separator,
                text: nil,
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil,
                parser: parser)
            return
        }

        if let kind = Self.structuralElements[name] {
            flushActiveBlock(parser)
            activeBlock = ActiveBlock(
                elementName: name,
                kind: kind,
                codeLanguage: kind == .code ? languageHint(attributeDict["class"]) : nil)
            return
        }
        if name == "code", activeBlock?.kind == .code, activeBlock?.codeLanguage == nil {
            activeBlock?.codeLanguage = languageHint(attributeDict["class"])
        }
        if name == "a", activeBlock != nil, activeBlock?.sourceURL == nil, let href = attributeDict["href"] {
            let url = normalizedHTTPURL(href, relativeTo: sourceURL)
            if url == nil { addWarning(.rejectedURLScheme) }
            activeBlock?.sourceURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0, !stoppedForLimit else { return }
        if isInCaption, !figureContexts.isEmpty {
            appendCollapsed(string, to: &figureContexts[figureContexts.count - 1].caption)
            return
        }
        guard var block = activeBlock else { return }
        if block.kind == .code {
            block.text += string
        } else {
            appendCollapsed(string, to: &block.text)
        }
        activeBlock = block
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = localName(elementName)
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        guard !stoppedForLimit, isAllowedElement(name, namespaceURI: namespaceURI) else { return }

        if name == "figcaption", isInCaption {
            isInCaption = false
            return
        }
        if name == "figure", let figure = figureContexts.popLast(), let caption = normalizedText(figure.caption) {
            if let imageIndex = figure.imageBlockIndex {
                blocks[imageIndex] = blocks[imageIndex].withCaption(caption)
            } else {
                appendBlock(
                    kind: .paragraph,
                    text: caption,
                    sourceURL: nil,
                    imageCandidateURL: nil,
                    caption: nil,
                    codeLanguage: nil,
                    parser: parser)
            }
            return
        }
        if activeBlock?.elementName == name {
            flushActiveBlock(parser)
        }
    }

    func finish() {
        guard !stoppedForLimit else { return }
        flushActiveBlock(nil)
        while let figure = figureContexts.popLast() {
            guard let caption = normalizedText(figure.caption) else { continue }
            if let imageIndex = figure.imageBlockIndex {
                blocks[imageIndex] = blocks[imageIndex].withCaption(caption)
            } else {
                appendBlock(
                    kind: .paragraph,
                    text: caption,
                    sourceURL: nil,
                    imageCandidateURL: nil,
                    caption: nil,
                    codeLanguage: nil,
                    parser: nil)
            }
        }
    }

    func addWarning(_ warning: ArticleSanitizationWarning) {
        append(warning, to: &warnings)
    }

    private func flushActiveBlock(_ parser: XMLParser?) {
        guard let block = activeBlock else { return }
        activeBlock = nil
        let text = block.kind == .code ? normalizedCode(block.text) : normalizedText(block.text)
        guard text != nil || block.kind == .code else { return }
        appendBlock(
            kind: block.kind,
            text: text,
            sourceURL: block.sourceURL,
            imageCandidateURL: nil,
            caption: nil,
            codeLanguage: block.codeLanguage,
            parser: parser)
    }

    private func appendBlock(
        kind: ArticleBlockKind,
        text: String?,
        sourceURL: URL?,
        imageCandidateURL: URL?,
        altText: String? = nil,
        caption: String?,
        codeLanguage: String?,
        parser: XMLParser?
    ) {
        guard blocks.count < ArticleWorkshopLimits.maxBlocks else {
            if let parser { stop(parser, warning: .blockLimitReached) }
            else { addWarning(.blockLimitReached) }
            return
        }
        let ordinal = blocks.count
        blocks.append(ArticleBlock(
            id: "article-\(captureID.uuidString)-b\(ordinal)",
            stableOrdinal: ordinal,
            kind: kind,
            text: text,
            sourceURL: sourceURL,
            imageCandidateURL: imageCandidateURL,
            altText: altText,
            caption: caption,
            codeLanguage: codeLanguage))
    }

    private func stop(_ parser: XMLParser, warning: ArticleSanitizationWarning) {
        stoppedForLimit = true
        addWarning(warning)
        parser.abortParsing()
    }

    private func isAllowedElement(_ name: String, namespaceURI: String?) -> Bool {
        guard namespaceURI == nil || namespaceURI?.isEmpty == true || namespaceURI == Self.xhtmlNamespace else { return false }
        return Self.structuralElements[name] != nil
            || Self.leafElements.contains(name)
            || Self.transparentElements.contains(name)
    }

    private func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
    }

    private func languageHint(_ classes: String?) -> String? {
        guard let classes else { return nil }
        return classes.split(separator: " ").compactMap { value in
            let className = String(value)
            if className.hasPrefix("language-") { return String(className.dropFirst("language-".count)) }
            if className.hasPrefix("lang-") { return String(className.dropFirst("lang-".count)) }
            return nil
        }.first
    }

    private func preferredImageURL(attributes: [String: String]) -> URL? {
        let srcsetCandidates = (attributes["srcset"] ?? "")
            .split(separator: ",")
            .compactMap { entry -> (url: URL, score: Double)? in
                let fields = entry.split(whereSeparator: { $0.isWhitespace })
                guard let raw = fields.first,
                    let url = normalizedHTTPURL(String(raw), relativeTo: sourceURL)
                else { return nil }
                let descriptor = fields.dropFirst().first.map(String.init) ?? "1x"
                let score: Double
                if descriptor.hasSuffix("w") {
                    score = Double(descriptor.dropLast()) ?? 0
                } else if descriptor.hasSuffix("x") {
                    score = (Double(descriptor.dropLast()) ?? 0) * 10_000
                } else {
                    score = 0
                }
                return (url, score)
            }
        if let best = srcsetCandidates.max(by: { $0.score < $1.score })?.url {
            return best
        }
        return normalizedHTTPURL(attributes["src"], relativeTo: sourceURL)
    }

    private func shouldSkipPresentationFurniture(
        name: String,
        attributes: [String: String]
    ) -> Bool {
        if ["aside", "nav", "footer"].contains(name) { return true }
        if attributes["hidden"] != nil || attributes["aria-hidden"]?.lowercased() == "true" {
            return true
        }
        let role = attributes["role"]?.lowercased() ?? ""
        if ["banner", "complementary", "contentinfo", "navigation"].contains(role) {
            return true
        }
        let tokens = ((attributes["class"] ?? "") + " " + (attributes["id"] ?? ""))
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
        let furniture: Set<Substring> = [
            "ad", "ads", "advert", "advertisement", "promo", "recommendation",
            "recommendations", "related", "share", "social", "sponsor", "sponsored",
        ]
        return tokens.contains(where: furniture.contains)
    }
}

private nonisolated func normalizedHTTPURL(_ rawValue: String?, relativeTo sourceURL: URL?) -> URL? {
    guard let rawValue = normalizedText(rawValue) else { return nil }
    let resolved: URL?
    if let sourceURL {
        resolved = URL(string: rawValue, relativeTo: sourceURL)?.absoluteURL
    } else {
        resolved = URL(string: rawValue)
    }
    guard let url = resolved, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
    guard components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
    return url
}

private nonisolated func normalizedText(_ text: String?) -> String? {
    guard let text else { return nil }
    var result = ""
    appendCollapsed(text, to: &result)
    return result.isEmpty ? nil : result
}

private nonisolated func normalizedCode(_ text: String) -> String? {
    let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
}

private nonisolated func appendCollapsed(_ text: String, to output: inout String) {
    for character in text {
        if character.isWhitespace {
            if !output.isEmpty, output.last != " " { output.append(" ") }
        } else {
            output.append(character)
        }
    }
}

private nonisolated func append(_ warning: ArticleSanitizationWarning, to warnings: inout [ArticleSanitizationWarning]) {
    if !warnings.contains(warning) { warnings.append(warning) }
}
