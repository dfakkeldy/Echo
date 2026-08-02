// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation

#if canImport(ZIPFoundation)
    import ZIPFoundation

    nonisolated struct AnthologyEPUBExtractionBuffer: Sendable {
        enum Error: Swift.Error, Equatable, Sendable {
            case limitExceeded
        }

        let maxBytes: UInt64
        private(set) var data = Data()

        mutating func consume(_ chunk: Data) throws {
            let currentSize = UInt64(data.count)
            guard currentSize <= maxBytes,
                UInt64(chunk.count) <= maxBytes - currentSize
            else {
                throw Error.limitExceeded
            }
            data.append(chunk)
        }
    }

    nonisolated struct AnthologyEPUBPreflight: Sendable {
        enum Error: Swift.Error, Equatable, Sendable {
            case invalidArchive
            case unsafeEntry
            case duplicateEntry
            case invalidMimetype
            case missingRequiredEntry
            case malformedXML
            case invalidPackage
            case invalidNavigation
            case invalidChapter
            case invalidSourceURL
            case manifestDigestMismatch
            case resultDigestMismatch
        }

        func validate(
            epubAt url: URL,
            against manifest: AnthologyBuildManifest
        ) throws -> AnthologyEPUBBuildResult {
            let archiveMetadata = try regularFileMetadata(at: url)
            guard archiveMetadata.size <= ArchiveExtractionLimits.maxTotalBytes + 16 * 1_024 * 1_024
            else {
                throw Error.invalidArchive
            }
            let archive: Archive
            do {
                archive = try Archive(url: url, accessMode: .read)
            } catch {
                throw Error.invalidArchive
            }
            var entries: [Entry] = []
            for entry in archive {
                guard entries.count < 10_000 else { throw Error.invalidArchive }
                entries.append(entry)
            }
            guard entries.count <= 10_000,
                entries.first?.path == "mimetype",
                entries.first?.isCompressed == false
            else {
                throw Error.invalidMimetype
            }

            var files: [String: Data] = [:]
            var declaredTotal: UInt64 = 0
            var actualTotal: UInt64 = 0
            for entry in entries {
                guard entry.type == .file else { throw Error.unsafeEntry }
                let path = try safePath(entry.path)
                guard files[path] == nil else { throw Error.duplicateEntry }
                do {
                    declaredTotal = try ArchiveExtractionLimits.checkedTotal(
                        addingEntryOfSize: UInt64(entry.uncompressedSize),
                        to: declaredTotal)
                } catch {
                    throw Error.invalidArchive
                }
                guard actualTotal <= ArchiveExtractionLimits.maxTotalBytes else {
                    throw Error.invalidArchive
                }
                var buffer = AnthologyEPUBExtractionBuffer(
                    maxBytes: min(
                        ArchiveExtractionLimits.maxEntryBytes,
                        ArchiveExtractionLimits.maxTotalBytes - actualTotal))
                do {
                    _ = try archive.extract(entry) { chunk in
                        try buffer.consume(chunk)
                    }
                } catch {
                    throw Error.invalidArchive
                }
                let data = buffer.data
                guard data.count == Int(entry.uncompressedSize)
                else {
                    throw Error.invalidArchive
                }
                do {
                    actualTotal = try ArchiveExtractionLimits.checkedTotal(
                        addingEntryOfSize: UInt64(data.count),
                        to: actualTotal)
                } catch {
                    throw Error.invalidArchive
                }
                files[path] = data
            }

            guard files["mimetype"] == Data("application/epub+zip".utf8) else {
                throw Error.invalidMimetype
            }
            guard let containerData = files["META-INF/container.xml"],
                let packageData = files["EPUB/package.opf"],
                let navData = files["EPUB/nav.xhtml"]
            else {
                throw Error.missingRequiredEntry
            }
            let container = try parseXML(containerData)
            guard container.name == "container",
                container.attributes["xmlns"] == Self.containerNamespace,
                container.children.map(\.name) == ["rootfiles"],
                container.children[0].children.map(\.name) == ["rootfile"],
                container.children[0].children[0].attributes["full-path"]
                    == "EPUB/package.opf",
                container.children[0].children[0].attributes["media-type"]
                    == "application/oebps-package+xml"
            else {
                throw Error.invalidPackage
            }

            let chapters = manifest.chapters.sorted { $0.order < $1.order }
            let manifestData: Data
            do {
                let encoder = JSONEncoder.articleWorkshop
                encoder.outputFormatting = [.sortedKeys]
                manifestData = try encoder.encode(manifest)
            } catch {
                throw Error.manifestDigestMismatch
            }
            let manifestDigest = Self.sha256(manifestData)
            try validateGeneratedResources(
                files: files,
                manifest: manifest,
                manifestDigest: manifestDigest,
                chapters: chapters)
            let package = try parseXML(packageData)
            try validatePackage(
                package,
                files: files,
                manifest: manifest,
                manifestDigest: manifestDigest,
                chapters: chapters)
            try validateNavigation(try parseXML(navData), chapters: chapters)
            for chapter in chapters {
                let path = "EPUB/articles/article-s\(chapter.stableSlot).xhtml"
                guard let data = files[path] else { throw Error.missingRequiredEntry }
                try validateChapter(
                    try parseXML(data),
                    against: chapter,
                    imageAssets: manifest.imageAssets ?? [])
            }
            guard let coverPage = files["EPUB/cover.xhtml"] else {
                throw Error.missingRequiredEntry
            }
            try validateCoverPage(
                try parseXML(coverPage),
                manifest: manifest)
            try validateCover(files: files, manifest: manifest)
            try validateArticleImages(files: files, manifest: manifest)

            return AnthologyEPUBBuildResult(
                temporaryURL: url,
                epubSHA256: try hashFile(at: url, expected: archiveMetadata),
                manifestSHA256: manifestDigest,
                identifier: manifest.epubIdentifier,
                revision: manifest.revision)
        }

        func validate(
            result: AnthologyEPUBBuildResult,
            against manifest: AnthologyBuildManifest
        ) throws {
            let checked = try validate(epubAt: result.temporaryURL, against: manifest)
            guard checked == result else { throw Error.resultDigestMismatch }
        }

        private func validatePackage(
            _ package: XMLNode,
            files: [String: Data],
            manifest: AnthologyBuildManifest,
            manifestDigest: String,
            chapters: [AnthologyChapterManifest]
        ) throws {
            guard package.name == "package",
                package.attributes["xmlns"] == Self.opfNamespace,
                package.attributes["unique-identifier"] == "pub-id",
                package.attributes["version"] == "3.0",
                package.children.map(\.name) == ["metadata", "manifest", "spine"]
            else {
                throw Error.invalidPackage
            }
            let metadataNode = package.children[0]
            let manifestNode = package.children[1]
            let spineNode = package.children[2]
            guard manifestNode.children.allSatisfy({ $0.name == "item" }),
                spineNode.children.allSatisfy({ $0.name == "itemref" })
            else {
                throw Error.invalidPackage
            }
            let identifiers = metadataNode.children.filter { $0.name == "identifier" }
            guard identifiers.count == 1,
                identifiers[0].attributes["id"] == "pub-id",
                identifiers[0].trimmedText == manifest.epubIdentifier
            else {
                throw Error.invalidPackage
            }
            let packageIDs = package.allDescendants.compactMap { $0.attributes["id"] }
            guard Set(packageIDs).count == packageIDs.count else {
                throw Error.invalidPackage
            }
            let titles = metadataNode.children.filter { $0.name == "title" }
            let subtitleMatches =
                manifest.subtitle.map { subtitle in
                    titles.contains(where: {
                        $0.attributes["id"] == "subtitle" && $0.trimmedText == subtitle
                    })
                }
                ?? titles.allSatisfy({
                    $0.attributes["id"] != "subtitle"
                })
            let creators = metadataNode.children.filter { $0.name == "creator" }.map(\.trimmedText)
            let languages = metadataNode.children.filter { $0.name == "language" }.map(
                \.trimmedText)
            guard
                titles.contains(where: {
                    $0.attributes["id"] == nil && $0.trimmedText == manifest.title
                }),
                subtitleMatches,
                creators == [manifest.creator],
                languages == [manifest.language]
            else {
                throw Error.invalidPackage
            }
            let metadata = Dictionary(
                metadataNode.children.filter { $0.name == "meta" }.compactMap { node in
                    node.attributes["property"].map { ($0, node.trimmedText) }
                },
                uniquingKeysWith: { _, _ in "" })
            guard metadata["echo:manifest-sha256"] == manifestDigest else {
                throw Error.manifestDigestMismatch
            }
            guard metadata["echo:revision"] == String(manifest.revision) else {
                throw Error.invalidPackage
            }
            guard metadata["dcterms:modified"] == Self.timestamp(manifest.modifiedAt) else {
                throw Error.invalidPackage
            }

            let coverExtension =
                manifest.coverPath
                .map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "svg"
            let coverMediaType =
                coverExtension == "svg"
                ? "image/svg+xml"
                : coverExtension == "png" ? "image/png" : "image/jpeg"
            var expected: [String: (href: String, media: String, properties: String?)] = [
                "nav": ("nav.xhtml", EPUBXMLWriter.xhtmlMediaType, "nav"),
                "styles": ("styles.css", "text/css", nil),
                "cover-page": ("cover.xhtml", EPUBXMLWriter.xhtmlMediaType, nil),
                "cover-image": (
                    "images/cover.\(coverExtension)",
                    coverMediaType,
                    "cover-image"
                ),
            ]
            for chapter in chapters {
                expected["chapter-s\(chapter.stableSlot)"] = (
                    "articles/article-s\(chapter.stableSlot).xhtml",
                    EPUBXMLWriter.xhtmlMediaType,
                    nil
                )
            }
            var emittedImagePaths = Set<String>()
            for image in manifest.imageAssets ?? []
            where emittedImagePaths.insert(image.archivePath).inserted {
                expected["article-image-\(image.sha256)"] = (
                    String(image.archivePath.dropFirst("EPUB/".count)),
                    image.mediaType,
                    nil)
            }
            let itemNodes = manifestNode.children
            guard itemNodes.count == expected.count else { throw Error.invalidPackage }
            var itemIDs = Set<String>()
            var itemHrefs = Set<String>()
            for item in itemNodes {
                guard let id = item.attributes["id"],
                    let href = item.attributes["href"],
                    let media = item.attributes["media-type"],
                    let expectedItem = expected[id],
                    itemIDs.insert(id).inserted,
                    itemHrefs.insert(href).inserted,
                    href == expectedItem.href,
                    media == expectedItem.media,
                    item.attributes["properties"] == expectedItem.properties,
                    files["EPUB/\(try safePath(href))"] != nil
                else {
                    throw Error.invalidPackage
                }
            }
            let declared = Set(itemHrefs.map { "EPUB/\($0)" })
                .union(["mimetype", "META-INF/container.xml", "EPUB/package.opf"])
            guard declared == Set(files.keys) else { throw Error.invalidPackage }

            let spine = spineNode.children.compactMap {
                $0.attributes["idref"]
            }
            let expectedSpine =
                ["cover-page"]
                + chapters.map {
                    "chapter-s\($0.stableSlot)"
                }
            guard spine == expectedSpine, spine.allSatisfy(itemIDs.contains) else {
                throw Error.invalidPackage
            }
        }

        private func validateNavigation(
            _ nav: XMLNode,
            chapters: [AnthologyChapterManifest]
        ) throws {
            guard isXHTMLDocument(nav),
                nav.attributes["xmlns:epub"] == Self.epubNamespace
            else {
                throw Error.invalidNavigation
            }
            let tocNodes = nav.descendants(named: "nav").filter {
                $0.attributes["epub:type"] == "toc"
            }
            guard tocNodes.count == 1 else { throw Error.invalidNavigation }
            let hrefs = tocNodes[0].descendants(named: "a").compactMap {
                $0.attributes["href"]
            }
            let expected = chapters.map { "articles/article-s\($0.stableSlot).xhtml" }
            let labels = tocNodes[0].descendants(named: "a").map(\.trimmedText)
            guard hrefs == expected,
                labels == chapters.map(\.title),
                Set(hrefs).count == hrefs.count
            else {
                throw Error.invalidNavigation
            }
        }

        private func validateChapter(
            _ document: XMLNode,
            against chapter: AnthologyChapterManifest,
            imageAssets: [ArticleImageAssetDescriptor]
        ) throws {
            guard isXHTMLDocument(document) else { throw Error.invalidChapter }
            let nodesWithIDs = document.allDescendants.compactMap { node -> (String, XMLNode)? in
                node.attributes["id"].map { ($0, node) }
            }
            let ids = nodesWithIDs.map(\.0)
            guard Set(ids).count == ids.count else { throw Error.invalidChapter }
            var expectedIndices = [0, 2, 900_000]
            if chapter.author != nil { expectedIndices.append(1) }
            expectedIndices.append(contentsOf: chapter.blocks.map { 1_000 + $0.stableOrdinal })
            let expectedIDs = Set(
                expectedIndices.map {
                    "echo-s\(chapter.stableSlot)-b\($0)"
                })
            guard Set(ids) == expectedIDs else { throw Error.invalidChapter }
            for (id, node) in nodesWithIDs {
                guard
                    let index = expectedIndices.first(where: {
                        id == "echo-s\(chapter.stableSlot)-b\($0)"
                    }),
                    node.attributes["data-echo-stable-slot"]
                        == String(chapter.stableSlot),
                    node.attributes["data-echo-block-index"] == String(index)
                else {
                    throw Error.invalidChapter
                }
            }
            let authorMatches =
                chapter.author.map { author in
                    nodesWithIDs.first(where: {
                        $0.0 == "echo-s\(chapter.stableSlot)-b1"
                    })?.1.trimmedText == author
                } ?? true
            guard
                nodesWithIDs.first(where: {
                    $0.0 == "echo-s\(chapter.stableSlot)-b0"
                })?.1.trimmedText == chapter.title,
                authorMatches
            else {
                throw Error.invalidChapter
            }
            let expectedPublication = [chapter.siteName, Self.date(chapter.capturedAt)]
                .compactMap { $0 }
                .joined(separator: " — ")
            guard
                nodesWithIDs.first(where: {
                    $0.0 == "echo-s\(chapter.stableSlot)-b2"
                })?.1.trimmedText == expectedPublication
            else {
                throw Error.invalidChapter
            }
            for block in chapter.blocks {
                let id = "echo-s\(chapter.stableSlot)-b\(1_000 + block.stableOrdinal)"
                let expectedCodeLanguage = block.codeLanguage
                guard let node = nodesWithIDs.first(where: { $0.0 == id })?.1,
                    node.name == Self.elementName(for: block.kind),
                    node.trimmedText
                        == (block.text ?? "").trimmingCharacters(
                            in: .whitespacesAndNewlines),
                    node.attributes["data-code-language"] == expectedCodeLanguage
                else {
                    throw Error.invalidChapter
                }
                if block.kind == .image {
                    guard let image = imageAssets.first(where: {
                        $0.owningBlockID == block.id
                    }),
                        node.attributes["src"]
                            == "../" + String(image.archivePath.dropFirst("EPUB/".count)),
                        node.attributes["alt"] == (image.altText ?? "")
                    else { throw Error.invalidChapter }
                }
            }
            guard
                let sourceNode = nodesWithIDs.first(where: {
                    $0.0 == "echo-s\(chapter.stableSlot)-b900000"
                })?.1,
                sourceNode.attributes["data-echo-narration"] == "skip",
                sourceNode.descendants(named: "a").count == 1,
                let sourceAnchor = sourceNode.descendants(named: "a").first,
                let href = sourceAnchor.attributes["href"],
                sourceAnchor.attributes["data-echo-narration"] == "skip",
                href == chapter.sourceURL.absoluteString,
                Self.isSafeHTTPURL(href)
            else {
                throw Error.invalidSourceURL
            }
            let links = document.descendants(named: "a")
            guard links.count == 1 else { throw Error.invalidSourceURL }
        }

        private func validateCoverPage(
            _ document: XMLNode,
            manifest: AnthologyBuildManifest
        ) throws {
            guard isXHTMLDocument(document),
                document.attributes["xmlns:epub"] == Self.epubNamespace
            else {
                throw Error.invalidPackage
            }
            let images = document.descendants(named: "img")
            let extensionName =
                manifest.coverPath
                .map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "svg"
            guard images.count == 1,
                images[0].attributes["src"] == "images/cover.\(extensionName)",
                images[0].attributes["alt"] == manifest.title
            else {
                throw Error.invalidPackage
            }
        }

        private func validateCover(
            files: [String: Data],
            manifest: AnthologyBuildManifest
        ) throws {
            if manifest.coverPath == nil {
                guard let svg = files["EPUB/images/cover.svg"] else {
                    throw Error.missingRequiredEntry
                }
                _ = try parseXML(svg)
                guard svg == AnthologyCoverRenderer.generatedCover(manifest: manifest) else {
                    throw Error.invalidPackage
                }
                return
            }
            guard let coverPath = manifest.coverPath else {
                throw Error.invalidPackage
            }
            let ext = URL(fileURLWithPath: coverPath).pathExtension.lowercased()
            guard let data = files["EPUB/images/cover.\(ext)"] else {
                throw Error.missingRequiredEntry
            }
            guard coverPath == "cover-\(Self.sha256(data)).\(ext)" else {
                throw Error.invalidPackage
            }
            switch ext {
            case "png":
                guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                else { throw Error.invalidPackage }
            case "jpg", "jpeg":
                guard data.starts(with: [0xFF, 0xD8]), data.suffix(2) == Data([0xFF, 0xD9])
                else { throw Error.invalidPackage }
            default:
                throw Error.invalidPackage
            }
        }

        private func validateGeneratedResources(
            files: [String: Data],
            manifest: AnthologyBuildManifest,
            manifestDigest: String,
            chapters: [AnthologyChapterManifest]
        ) throws {
            let cover = try expectedCoverAsset(files: files, manifest: manifest)
            var expected = [
                "META-INF/container.xml": Data(EPUBXMLWriter.container.utf8),
                "EPUB/package.opf": Data(
                    EPUBXMLWriter.package(
                        manifest: manifest,
                        manifestSHA256: manifestDigest,
                        chapters: chapters,
                        cover: cover,
                        articleImages: manifest.imageAssets ?? []
                    ).utf8),
                "EPUB/nav.xhtml": Data(
                    EPUBXMLWriter.navigation(
                        manifest: manifest,
                        chapters: chapters
                    ).utf8),
                "EPUB/styles.css": Data(EPUBXMLWriter.stylesheet.utf8),
                "EPUB/cover.xhtml": Data(
                    EPUBXMLWriter.coverPage(
                        manifest: manifest,
                        cover: cover
                    ).utf8),
            ]
            for chapter in chapters {
                expected["EPUB/articles/article-s\(chapter.stableSlot).xhtml"] = Data(
                    EPUBXMLWriter.chapter(
                        chapter,
                        language: manifest.language,
                        articleImages: manifest.imageAssets ?? []
                    ).utf8)
            }
            guard expected.allSatisfy({ files[$0.key] == $0.value }) else {
                throw Error.invalidPackage
            }
        }

        private func validateArticleImages(
            files: [String: Data],
            manifest: AnthologyBuildManifest
        ) throws {
            var expectedByPath: [String: ArticleImageAssetDescriptor] = [:]
            var total = 0
            for descriptor in manifest.imageAssets ?? [] {
                if let prior = expectedByPath[descriptor.archivePath] {
                    guard prior.sha256 == descriptor.sha256,
                        prior.byteCount == descriptor.byteCount,
                        prior.mediaType == descriptor.mediaType
                    else { throw Error.invalidPackage }
                    continue
                }
                expectedByPath[descriptor.archivePath] = descriptor
                guard let data = files[descriptor.archivePath],
                    data.count == descriptor.byteCount,
                    Self.sha256(data) == descriptor.sha256,
                    ArticleImageValidator.isValid(
                        data: data,
                        mediaType: descriptor.mediaType),
                    total <= ArticleWorkshopLimits.maxTotalImageBytes - data.count
                else { throw Error.invalidPackage }
                total += data.count
            }
        }

        private func expectedCoverAsset(
            files: [String: Data],
            manifest: AnthologyBuildManifest
        ) throws -> EPUBXMLWriter.CoverAsset {
            let extensionName =
                manifest.coverPath
                .map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "svg"
            let mediaType: String
            switch extensionName {
            case "svg": mediaType = "image/svg+xml"
            case "png": mediaType = "image/png"
            case "jpg", "jpeg": mediaType = "image/jpeg"
            default: throw Error.invalidPackage
            }
            let filename = "cover.\(extensionName)"
            guard let data = files["EPUB/images/\(filename)"] else {
                throw Error.missingRequiredEntry
            }
            return EPUBXMLWriter.CoverAsset(
                filename: filename,
                mediaType: mediaType,
                data: data)
        }

        private func isXHTMLDocument(_ document: XMLNode) -> Bool {
            document.name == "html"
                && document.attributes["xmlns"] == Self.xhtmlNamespace
                && document.children.map(\.name) == ["head", "body"]
        }

        private func safePath(_ path: String) throws -> String {
            guard path.isEmpty == false,
                path.hasPrefix("/") == false,
                path.contains("\\") == false,
                path.unicodeScalars.allSatisfy({ $0.value >= 0x20 }),
                path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    $0.isEmpty == false && $0 != "." && $0 != ".."
                })
            else {
                throw Error.unsafeEntry
            }
            return path
        }

        private func parseXML(_ data: Data) throws -> XMLNode {
            guard data.count <= Int(ArchiveExtractionLimits.maxEntryBytes) else {
                throw Error.malformedXML
            }
            guard data.count <= 16 * 1_024 * 1_024 else { throw Error.malformedXML }
            let uppercased = String(decoding: data, as: UTF8.self).uppercased()
            guard uppercased.contains("<!ENTITY") == false,
                uppercased.contains("<!DOCTYPE") == false
                    || (uppercased.components(separatedBy: "<!DOCTYPE HTML>").count == 2
                        && uppercased.replacingOccurrences(
                            of: "<!DOCTYPE HTML>",
                            with: ""
                        ).contains("<!DOCTYPE") == false)
            else {
                throw Error.malformedXML
            }
            let delegate = XMLTreeDelegate()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = false
            parser.shouldReportNamespacePrefixes = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(),
                parser.parserError == nil,
                delegate.isWithinLimits,
                let root = delegate.root
            else {
                throw Error.malformedXML
            }
            return root
        }

        private func regularFileMetadata(at url: URL) throws -> FileMetadata {
            var value = stat()
            guard lstat(url.path, &value) == 0,
                value.st_mode & S_IFMT == S_IFREG,
                value.st_size >= 0
            else {
                throw Error.invalidArchive
            }
            return FileMetadata(
                device: value.st_dev,
                inode: value.st_ino,
                size: UInt64(value.st_size))
        }

        private func hashFile(at url: URL, expected: FileMetadata) throws -> String {
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw Error.invalidArchive }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                opened.st_mode & S_IFMT == S_IFREG,
                opened.st_dev == expected.device,
                opened.st_ino == expected.inode,
                UInt64(opened.st_size) == expected.size
            else {
                throw Error.invalidArchive
            }
            var hasher = SHA256()
            var bytesRead: UInt64 = 0
            while let chunk = try handle.read(upToCount: 64 * 1_024), chunk.isEmpty == false {
                bytesRead += UInt64(chunk.count)
                guard bytesRead <= expected.size else { throw Error.invalidArchive }
                hasher.update(data: chunk)
            }
            guard bytesRead == expected.size,
                try regularFileMetadata(at: url) == expected
            else {
                throw Error.invalidArchive
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private static func isSafeHTTPURL(_ value: String) -> Bool {
            guard let components = URLComponents(string: value),
                let scheme = components.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                components.host?.isEmpty == false,
                components.user == nil,
                components.password == nil
            else {
                return false
            }
            return true
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func timestamp(_ value: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: value)
        }

        private static func date(_ value: Date) -> String? {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: value)
        }

        private static func elementName(for kind: ArticleBlockKind) -> String {
            switch kind {
            case .heading: "h2"
            case .paragraph, .listItem: "p"
            case .quote: "blockquote"
            case .code: "pre"
            case .separator: "hr"
            case .image: "img"
            }
        }

        private static let containerNamespace =
            "urn:oasis:names:tc:opendocument:xmlns:container"
        private static let opfNamespace = "http://www.idpf.org/2007/opf"
        private static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"
        private static let epubNamespace = "http://www.idpf.org/2007/ops"

        private struct FileMetadata: Equatable {
            let device: dev_t
            let inode: ino_t
            let size: UInt64
        }
    }

    private nonisolated final class XMLNode {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [XMLNode] = []

        init(name: String, attributes: [String: String]) {
            self.name = name.split(separator: ":").last.map(String.init) ?? name
            self.attributes = attributes
        }

        var trimmedText: String {
            flattenedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var flattenedText: String {
            text + children.map(\.flattenedText).joined()
        }

        var allDescendants: [XMLNode] {
            children + children.flatMap(\.allDescendants)
        }

        func descendants(named name: String) -> [XMLNode] {
            allDescendants.filter { $0.name == name }
        }
    }

    private nonisolated final class XMLTreeDelegate: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private(set) var isWithinLimits = true
        private var stack: [XMLNode] = []
        private var nodeCount = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            nodeCount += 1
            guard nodeCount <= 50_000, stack.count < 256 else {
                isWithinLimits = false
                parser.abortParsing()
                return
            }
            let node = XMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(node)
            } else if root == nil {
                root = node
            } else {
                parser.abortParsing()
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard
                stack.last?.name
                    == (elementName.split(separator: ":").last.map(String.init) ?? elementName)
            else {
                parser.abortParsing()
                return
            }
            _ = stack.popLast()
        }
    }
#endif
