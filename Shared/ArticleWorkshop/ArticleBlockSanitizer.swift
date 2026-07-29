// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ArticleBlockSanitizer {
    func sanitize(envelope: ArticleCaptureEnvelope) throws -> ArticleSnapshot {
        let xhtmlData = Data(envelope.payload.contentXHTML.utf8)
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
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        delegate.finish()

        if !parsed, !delegate.stoppedForLimit {
            delegate.addWarning(.parserFailure)
        }
        let blocks = delegate.blocks
        var warnings = delegate.warnings
        let hasReadableText = blocks.contains { block in
            guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty
        }
        if !hasReadableText { append(.noUsableText, to: &warnings) }
        let contentState: ArticleContentState
        if !hasReadableText {
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

    private static let skippedElements: Set<String> = [
        "script", "style", "form", "iframe", "frame", "frameset", "object", "embed", "svg", "math",
        "template", "noscript", "head", "input", "button", "select", "textarea", "option",
    ]

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

        let name = elementName.lowercased()
        if Self.skippedElements.contains(name) {
            skipDepth += 1
            return
        }
        guard skipDepth == 0 else { return }

        if name == "figure" {
            figureContexts.append(FigureContext())
            return
        }
        if name == "figcaption", !figureContexts.isEmpty {
            flushActiveBlock(parser)
            isInCaption = true
            return
        }
        if isInCaption { return }

        if name == "img" {
            flushActiveBlock(parser)
            guard imageCount < ArticleWorkshopLimits.maxImages else {
                stop(parser, warning: .imageCandidateLimitReached)
                return
            }
            imageCount += 1
            let candidate = normalizedHTTPURL(attributeDict["src"], relativeTo: sourceURL)
            if attributeDict["src"] != nil, candidate == nil { addWarning(.rejectedURLScheme) }
            appendBlock(
                kind: .image,
                text: nil,
                sourceURL: nil,
                imageCandidateURL: candidate,
                caption: nil,
                codeLanguage: nil,
                parser: parser)
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

        if let kind = blockKind(for: name) {
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
        let name = elementName.lowercased()
        if Self.skippedElements.contains(name) {
            skipDepth = max(0, skipDepth - 1)
            return
        }
        guard skipDepth == 0, !stoppedForLimit else { return }

        if name == "figcaption", isInCaption {
            isInCaption = false
            return
        }
        if name == "figure", let figure = figureContexts.popLast(), let imageIndex = figure.imageBlockIndex {
            let caption = normalizedText(figure.caption)
            if let caption { blocks[imageIndex] = blocks[imageIndex].withCaption(caption) }
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
            guard let imageIndex = figure.imageBlockIndex, let caption = normalizedText(figure.caption) else { continue }
            blocks[imageIndex] = blocks[imageIndex].withCaption(caption)
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
            caption: caption,
            codeLanguage: codeLanguage))
    }

    private func stop(_ parser: XMLParser, warning: ArticleSanitizationWarning) {
        stoppedForLimit = true
        addWarning(warning)
        parser.abortParsing()
    }

    private func blockKind(for elementName: String) -> ArticleBlockKind? {
        switch elementName {
        case "h1", "h2", "h3", "h4", "h5", "h6": .heading
        case "p": .paragraph
        case "li": .listItem
        case "blockquote": .quote
        case "pre": .code
        default: nil
        }
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
