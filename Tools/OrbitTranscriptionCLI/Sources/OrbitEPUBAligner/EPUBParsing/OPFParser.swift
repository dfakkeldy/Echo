import Foundation

struct OPFParser {
    func findOPFPath(from containerXMLPath: URL) throws -> String {
        let xmlData = try Data(contentsOf: containerXMLPath)
        let parser = ContainerXMLParser()
        parser.parse(xmlData)
        guard let path = parser.rootfilePath else {
            throw AlignmentError.missingOPF
        }
        return path
    }

    func parse(opfURL: URL, epubRoot: URL) throws -> EPUBStructure {
        let xmlData = try Data(contentsOf: opfURL)
        let parser = OPFXMLParser()
        parser.parse(xmlData)
        guard !parser.spineItems.isEmpty else {
            throw AlignmentError.spineEmpty
        }
        return EPUBStructure(
            title: parser.title ?? "Unknown",
            author: parser.author,
            spine: parser.spineItems.map { item in
                SpineItem(
                    id: item.id,
                    href: item.href,
                    mediaType: item.mediaType,
                    rawText: "",
                    markers: [],
                    textFormats: []
                )
            }
        )
    }
}

// MARK: - Private XML Parsers

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

private struct OPFManifestItem {
    let id: String
    let href: String
    let mediaType: String
}

private final class OPFXMLParser: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?
    var spineItems: [OPFManifestItem] = []
    private var manifestItems: [String: OPFManifestItem] = [:]
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

    private var currentText = ""

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentText = ""

        switch elementName {
        case "title", "dc:title":
            if title == nil { title = text }
        case "creator", "dc:creator":
            if author == nil { author = text }
        case "item":
            if let id = currentAttributes["id"],
               let href = currentAttributes["href"],
               let mediaType = currentAttributes["media-type"] {
                manifestItems[id] = OPFManifestItem(id: id, href: href, mediaType: mediaType)
            }
        default:
            break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        spineItems = spineIDRefs.compactMap { manifestItems[$0] }
    }
}
