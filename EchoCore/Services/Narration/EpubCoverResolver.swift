// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ZIPFoundation

/// Resolves an EPUB's cover image to raw JPEG/PNG bytes, suitable for embedding as
/// MP4 cover art. The cover is usually declared in the OPF as a manifest item —
/// either `<meta name="cover" content="id">` (EPUB 2) or a manifest item with
/// `properties="cover-image"` (EPUB 3) — NOT as an inline content image block, which
/// is why scanning `epub_block` image rows misses it. Cross-platform (no UIKit).
enum EpubCoverResolver {

    /// Cover bytes for a zipped EPUB archive, or nil if none is declared / the
    /// referenced file is not a JPEG/PNG in the archive.
    static func coverData(epubArchiveURL: URL) -> Data? {
        guard
            let archive = try? Archive(
                url: epubArchiveURL,
                accessMode: .read,
                pathEncoding: nil
            ),
            let opfPath = locateOPF(in: archive),
            let opfEntry = archive[opfPath],
            let opfData = data(for: opfEntry, in: archive)
        else { return nil }

        let delegate = CoverOPFDelegate()
        let parser = XMLParser(data: opfData)
        parser.delegate = delegate
        parser.parse()
        guard let href = delegate.resolvedCoverHref else { return nil }

        let opfDirectory = deletingLastPathComponent(opfPath)
        guard let imagePath = normalizedArchivePath(basePath: opfDirectory, relativePath: href),
            ["jpg", "jpeg", "png"].contains(pathExtension(imagePath).lowercased()),
            let imageEntry = archive[imagePath]
        else { return nil }
        return data(for: imageEntry, in: archive)
    }

    /// Cover bytes for an *expanded* (unzipped) EPUB directory, or nil if none is
    /// declared / the referenced file isn't a JPEG/PNG that exists on disk.
    static func coverData(expandedEPUBDir: URL) -> Data? {
        guard let opfURL = locateOPF(in: expandedEPUBDir),
            let opfData = try? Data(contentsOf: opfURL)
        else { return nil }

        let delegate = CoverOPFDelegate()
        let parser = XMLParser(data: opfData)
        parser.delegate = delegate
        parser.parse()
        guard let href = delegate.resolvedCoverHref else { return nil }

        // hrefs are relative to the OPF's directory and may be percent-encoded.
        let decoded = href.removingPercentEncoding ?? href
        let imageURL =
            opfURL.deletingLastPathComponent()
            .appendingPathComponent(decoded).standardizedFileURL
        // Contain to the EPUB root so a `../../` href can't read outside the book.
        let root = expandedEPUBDir.standardizedFileURL.path
        guard imageURL.path == root || imageURL.path.hasPrefix(root + "/"),
            ["jpg", "jpeg", "png"].contains(imageURL.pathExtension.lowercased()),
            FileManager.default.fileExists(atPath: imageURL.path)
        else { return nil }
        return try? Data(contentsOf: imageURL)
    }

    /// Cover bytes for a book identified by its `audiobookID`, which is either the
    /// `.epub` file's URL (standalone narration) or the containing folder's URL
    /// (imported book). Resolves the OPF-declared cover the same way the live
    /// reader/lock screen does, so exports and Now Playing match.
    ///
    /// The `audiobookID` is a string, so the file URL is reconstructed rather than
    /// carried from a picker/bookmark — `startAccessingSecurityScopedResource()`
    /// on a reconstructed URL returns `false` and grants nothing. This relies on
    /// the caller already holding **ambient** access to the book's path (the live
    /// export and narration cover-copy both run while the book is loaded and
    /// `PlayerModel.securityScope` holds it), exactly as the sibling
    /// `ExportMetadataResolver.folderSidecarArtworkData` does. Best-effort: returns
    /// nil when the id isn't a reachable file URL, the path isn't accessible, or no
    /// OPF cover exists — callers fall back to the inline-image-block heuristic.
    static func coverData(forAudiobookID audiobookID: String, fileManager: FileManager = .default)
        -> Data?
    {
        guard let url = URL(string: audiobookID), url.isFileURL else { return nil }

        // Standalone narration: the id IS the .epub (zipped) or an expanded dir.
        if url.pathExtension.lowercased() == "epub" {
            return coverData(epubArchiveURL: url) ?? coverData(expandedEPUBDir: url)
        }

        // Imported book: the id is the containing folder — find its .epub.
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }
        if let epub =
            (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .first(where: { $0.pathExtension.lowercased() == "epub" })
        {
            return coverData(epubArchiveURL: epub) ?? coverData(expandedEPUBDir: epub)
        }

        // The id may itself be an expanded EPUB directory (META-INF + OPF on disk).
        return coverData(expandedEPUBDir: url)
    }

    /// Finds the OPF: first via `META-INF/container.xml`'s rootfile, else the first
    /// `*.opf` anywhere under the directory.
    private static func locateOPF(in dir: URL) -> URL? {
        let containerURL = dir.appendingPathComponent("META-INF/container.xml")
        if let data = try? Data(contentsOf: containerURL) {
            let delegate = ContainerDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            if let path = delegate.rootfilePath {
                let decoded = path.removingPercentEncoding ?? path
                let url = dir.appendingPathComponent(decoded)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "opf" { return url }
        }
        return nil
    }

    /// Finds the OPF in a ZIP archive: first via `META-INF/container.xml`, then
    /// via the first `*.opf` entry.
    private static func locateOPF(in archive: Archive) -> String? {
        if let containerEntry = archive["META-INF/container.xml"],
            let data = data(for: containerEntry, in: archive)
        {
            let delegate = ContainerDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            if let path = delegate.rootfilePath,
                let normalized = normalizedArchivePath(basePath: "", relativePath: path),
                archive[normalized] != nil
            {
                return normalized
            }
        }

        return archive.first { pathExtension($0.path).lowercased() == "opf" }?.path
    }

    private static func data(for entry: Entry, in archive: Archive) -> Data? {
        var result = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                result.append(chunk)
            }
        } catch {
            return nil
        }
        return result
    }

    private static func normalizedArchivePath(basePath: String, relativePath: String) -> String? {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        guard !decoded.hasPrefix("/") else { return nil }

        var components =
            basePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    private static func deletingLastPathComponent(_ path: String) -> String {
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slashIndex])
    }

    private static func pathExtension(_ path: String) -> String {
        guard let dotIndex = path.lastIndex(of: ".") else { return "" }
        return String(path[path.index(after: dotIndex)...])
    }
}

/// Reads `META-INF/container.xml` for the OPF rootfile path.
private final class ContainerDelegate: NSObject, XMLParserDelegate {
    var rootfilePath: String?
    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "rootfile", rootfilePath == nil {
            rootfilePath = attributeDict["full-path"]
        }
    }
}

/// Extracts the cover image href from an OPF: the EPUB 3 `properties="cover-image"`
/// manifest item wins; otherwise the EPUB 2 `<meta name="cover" content="id">` → the
/// manifest item with that id.
private final class CoverOPFDelegate: NSObject, XMLParserDelegate {
    private var coverMetaID: String?
    private var hrefByID: [String: String] = [:]
    private var coverImageHref: String?

    var resolvedCoverHref: String? {
        coverImageHref ?? coverMetaID.flatMap { hrefByID[$0] }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = elementName.hasSuffix(":item") ? "item" : elementName
        switch name {
        case "meta":
            if attributeDict["name"] == "cover" { coverMetaID = attributeDict["content"] }
        case "item":
            guard let id = attributeDict["id"], let href = attributeDict["href"] else { return }
            hrefByID[id] = href
            let properties = (attributeDict["properties"] ?? "").split(separator: " ")
            if properties.contains("cover-image") { coverImageHref = href }
        default:
            break
        }
    }
}
