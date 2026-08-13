// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ZIPFoundation

/// Resolves an EPUB's OPF `<dc:title>`/`<dc:creator>` for Library metadata
/// enrichment: separately imported epubs persist folder-name titles and nil
/// authors, which blocks `EditionMatcher` from pairing them with the audio
/// edition. Shares `EpubCoverResolver`'s OPF-location machinery (container.xml
/// rootfile, else first `*.opf`; zipped archive or expanded directory).
/// Cross-platform (Foundation + ZIPFoundation only — no UIKit).
/// `nonisolated`: pure file I/O with no shared state, so the Library's
/// shelf-load enrichment can run it off the main actor via `Task.detached`.
nonisolated enum EpubMetadataResolver {

    /// OPF title/author for a zipped EPUB archive, or nil when no OPF is found.
    /// A located OPF that lacks the fields yields `(nil, nil)`.
    static func metadata(epubArchiveURL: URL) -> (title: String?, author: String?)? {
        guard
            let archive = try? Archive(
                url: epubArchiveURL,
                accessMode: .read,
                pathEncoding: nil
            ),
            let opfPath = EpubCoverResolver.locateOPF(in: archive),
            let opfEntry = archive[opfPath],
            let opfData = EpubCoverResolver.data(for: opfEntry, in: archive)
        else { return nil }
        return parse(opfData)
    }

    /// OPF title/author for an *expanded* (unzipped) EPUB directory, or nil when
    /// no OPF is found.
    static func metadata(expandedEPUBDir: URL) -> (title: String?, author: String?)? {
        guard let opfURL = EpubCoverResolver.locateOPF(in: expandedEPUBDir),
            let opfData = try? Data(contentsOf: opfURL)
        else { return nil }
        return parse(opfData)
    }

    /// OPF title/author for a book identified by its `audiobookID`, which is
    /// either the `.epub` file's URL (zipped or expanded dir) or the containing
    /// folder's URL. Same best-effort resolution contract as
    /// `EpubCoverResolver.coverData(forAudiobookID:)`: the security-scope start
    /// is attempted but relies on ambient access when it fails, and any missing
    /// file / unreadable OPF returns nil.
    static func metadata(forAudiobookID audiobookID: String, fileManager: FileManager = .default)
        -> (title: String?, author: String?)?
    {
        guard let url = URL(string: audiobookID), url.isFileURL else { return nil }

        // Standalone narration: the id IS the .epub (zipped) or an expanded dir.
        if url.pathExtension.lowercased() == "epub" {
            return metadata(epubArchiveURL: url) ?? metadata(expandedEPUBDir: url)
        }

        // Imported book: the id is the containing folder — find its .epub.
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }
        if let epub =
            (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .first(where: { $0.pathExtension.lowercased() == "epub" })
        {
            return metadata(epubArchiveURL: epub) ?? metadata(expandedEPUBDir: epub)
        }

        // The id may itself be an expanded EPUB directory (META-INF + OPF on disk).
        return metadata(expandedEPUBDir: url)
    }

    private static func parse(_ opfData: Data) -> (title: String?, author: String?) {
        let delegate = MetadataOPFDelegate()
        let parser = XMLParser(data: opfData)
        parser.delegate = delegate
        parser.parse()
        return (delegate.title, delegate.creator)
    }
}

/// Extracts the first non-empty `<dc:title>` and `<dc:creator>` inside the OPF
/// `<metadata>` element, trimmed. XMLParser reports element names as authored,
/// so namespace-qualified names ("dc:title", "opf:metadata") are matched by
/// suffix — the same trick `CoverOPFDelegate` uses for `:item`.
nonisolated private final class MetadataOPFDelegate: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var creator: String?

    private enum Field { case title, creator }
    private var insideMetadata = false
    private var currentField: Field?
    private var buffer = ""

    private func matches(_ elementName: String, _ localName: String) -> Bool {
        elementName == localName || elementName.hasSuffix(":" + localName)
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if matches(elementName, "metadata") {
            insideMetadata = true
        } else if insideMetadata, title == nil, matches(elementName, "title") {
            currentField = .title
            buffer = ""
        } else if insideMetadata, creator == nil, matches(elementName, "creator") {
            currentField = .creator
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentField != nil else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        if matches(elementName, "metadata") {
            insideMetadata = false
            return
        }
        guard let field = currentField,
            matches(elementName, field == .title ? "title" : "creator")
        else { return }
        currentField = nil
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch field {
        case .title: title = trimmed
        case .creator: creator = trimmed
        }
    }
}
