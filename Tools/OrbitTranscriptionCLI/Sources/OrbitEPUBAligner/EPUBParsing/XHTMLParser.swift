import Foundation

struct XHTMLParseResult {
    let rawText: String
    let markers: [SyncMarker]
    let textFormats: [TextFormat]
}

struct XHTMLParser {
    func parse(xhtml: String, baseHref: String) throws -> XHTMLParseResult {
        let parser = XHTMLContentParser()
        parser.parse(xhtmlString: xhtml)
        return XHTMLParseResult(
            rawText: parser.outputText.trimmingCharacters(in: .whitespacesAndNewlines),
            markers: parser.markers,
            textFormats: parser.textFormats
        )
    }
}

// MARK: - Private XML parser

private final class XHTMLContentParser: NSObject, XMLParserDelegate {
    var outputText = ""
    var markers: [SyncMarker] = []
    var textFormats: [TextFormat] = []
    private var skipDepth = 0
    private var pendingFormatStack: [(FormatType, Int)] = []
    private var pendingHeadingText = ""
    private var isInHeading = false
    private let skipTags: Set<String> = ["script", "style", "head"]

    func parse(xhtmlString: String) {
        guard let data = xhtmlString.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if skipTags.contains(elementName) {
            skipDepth += 1
            return
        }
        guard skipDepth == 0 else { return }

        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
            isInHeading = true
            pendingHeadingText = ""
        } else if elementName == "img", let src = attributes["src"] {
            let marker = SyncMarker(type: .image, payload: src, epubCharOffset: outputText.count)
            markers.append(marker)
        } else if elementName == "a", let href = attributes["href"] {
            let marker = SyncMarker(type: .hyperlink, payload: href, epubCharOffset: outputText.count)
            markers.append(marker)
        } else if elementName == "blockquote" {
            let marker = SyncMarker(type: .blockquote, payload: "", epubCharOffset: outputText.count)
            markers.append(marker)
        } else if elementName == "hr" {
            let marker = SyncMarker(type: .horizontalRule, payload: "", epubCharOffset: outputText.count)
            markers.append(marker)
        } else if elementName == "em" || elementName == "i" {
            pendingFormatStack.append((.italic, outputText.count))
        } else if elementName == "strong" || elementName == "b" {
            pendingFormatStack.append((.bold, outputText.count))
        } else if elementName == "u" {
            pendingFormatStack.append((.underline, outputText.count))
        }

        if ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"].contains(elementName) {
            if !outputText.isEmpty && !outputText.hasSuffix(" ") {
                outputText += " "
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isInHeading {
            pendingHeadingText += trimmed + " "
        }
        if !trimmed.isEmpty {
            outputText += trimmed + " "
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if skipTags.contains(elementName) {
            skipDepth = max(0, skipDepth - 1)
            return
        }
        guard skipDepth == 0 else { return }

        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
            isInHeading = false
            let headingText = pendingHeadingText.trimmingCharacters(in: .whitespaces)
            if !headingText.isEmpty {
                let markerOffset = max(0, outputText.count - headingText.count - 1)
                let marker = SyncMarker(type: .chapterStart, payload: headingText, epubCharOffset: markerOffset)
                markers.append(marker)
            }
        }

        let formatType: FormatType?
        switch elementName {
        case "em", "i":  formatType = .italic
        case "strong", "b": formatType = .bold
        case "u": formatType = .underline
        default: formatType = nil
        }
        if let type = formatType,
           let idx = pendingFormatStack.lastIndex(where: { $0.0 == type }) {
            let (_, start) = pendingFormatStack.remove(at: idx)
            let end = max(start, outputText.count - 1)
            textFormats.append(TextFormat(type: type, range: start...end))
        }
    }
}
