// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum EPUBXMLWriter {
    static let xhtmlMediaType = "application/xhtml+xml"

    static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
    }

    static let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    static let stylesheet = """
        @charset "UTF-8";
        :root { color-scheme: light dark; }
        body { font-family: serif; line-height: 1.55; margin: 5%; }
        h1 { line-height: 1.15; }
        .byline, .publication, .source { color: currentColor; font-family: sans-serif; opacity: 0.8; }
        .list-item { margin-left: 1.5em; }
        pre { overflow-wrap: anywhere; white-space: pre-wrap; }
        img { height: auto; max-width: 100%; }
        """

    static func package(
        manifest: AnthologyBuildManifest,
        manifestSHA256: String,
        chapters: [AnthologyChapterManifest],
        cover: CoverAsset,
        articleImages: [ArticleImageAssetDescriptor] = []
    ) -> String {
        let modified = timestamp(manifest.modifiedAt)
        let chapterItems = chapters.map {
            """
                <item id="chapter-s\($0.stableSlot)" href="articles/article-s\($0.stableSlot).xhtml" media-type="\(xhtmlMediaType)"/>
            """
        }.joined(separator: "\n")
        let spine = chapters.map {
            #"    <itemref idref="chapter-s\#($0.stableSlot)"/>"#
        }.joined(separator: "\n")
        var emittedImagePaths = Set<String>()
        let imageItems = articleImages.compactMap { image -> String? in
            guard emittedImagePaths.insert(image.archivePath).inserted else { return nil }
            let href = String(image.archivePath.dropFirst("EPUB/".count))
            return "    <item id=\"article-image-\(image.sha256)\" href=\"\(escapeAttribute(href))\" media-type=\"\(image.mediaType)\"/>"
        }.joined(separator: "\n")
        let subtitle =
            manifest.subtitle.map {
                "  <dc:title id=\"subtitle\">\(escapeText($0))</dc:title>"
                    + "\n  <meta property=\"title-type\" refines=\"#subtitle\">subtitle</meta>"
            } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf"
                     xmlns:dc="http://purl.org/dc/elements/1.1/"
                     version="3.0"
                     unique-identifier="pub-id"
                     prefix="echo: https://echo.app/ns/article-workshop#">
              <metadata>
                <dc:identifier id="pub-id">\(escapeText(manifest.epubIdentifier))</dc:identifier>
                <dc:title>\(escapeText(manifest.title))</dc:title>
            \(subtitle)
                <dc:creator>\(escapeText(manifest.creator))</dc:creator>
                <dc:language>\(escapeText(manifest.language))</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
                <meta property="echo:manifest-sha256">\(manifestSHA256)</meta>
                <meta property="echo:revision">\(manifest.revision)</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="\(xhtmlMediaType)" properties="nav"/>
                <item id="styles" href="styles.css" media-type="text/css"/>
                <item id="cover-page" href="cover.xhtml" media-type="\(xhtmlMediaType)"/>
                <item id="cover-image" href="images/\(cover.filename)" media-type="\(cover.mediaType)" properties="cover-image"/>
            \(imageItems)
            \(chapterItems)
              </manifest>
              <spine>
                <itemref idref="cover-page" linear="no"/>
            \(spine)
              </spine>
            </package>
            """
    }

    static func navigation(
        manifest: AnthologyBuildManifest,
        chapters: [AnthologyChapterManifest]
    ) -> String {
        let items = chapters.map {
            """
                    <li><a href="articles/article-s\($0.stableSlot).xhtml">\(escapeText($0.title))</a></li>
            """
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml"
                  xmlns:epub="http://www.idpf.org/2007/ops"
                  xml:lang="\(escapeAttribute(manifest.language))">
              <head>
                <title>\(escapeText(manifest.title))</title>
              </head>
              <body>
                <nav epub:type="toc" id="toc">
                  <h1>\(escapeText(manifest.title))</h1>
                  <ol>
            \(items)
                  </ol>
                </nav>
              </body>
            </html>
            """
    }

    static func coverPage(
        manifest: AnthologyBuildManifest,
        cover: CoverAsset
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"
              xml:lang="\(escapeAttribute(manifest.language))">
          <head>
            <title>Cover</title>
            <meta name="viewport" content="width=1600,height=2560"/>
          </head>
          <body epub:type="cover">
            <img src="images/\(escapeAttribute(cover.filename))" alt="\(escapeAttribute(manifest.title))"/>
          </body>
        </html>
        """
    }

    static func chapter(
        _ chapter: AnthologyChapterManifest,
        language: String,
        articleImages: [ArticleImageAssetDescriptor] = []
    ) -> String {
        let slot = chapter.stableSlot
        var content = [
            boundary(
                tag: "h1",
                slot: slot,
                index: 0,
                text: chapter.title)
        ]
        if let author = chapter.author {
            content.append(
                boundary(
                    tag: "p",
                    cssClass: "byline",
                    slot: slot,
                    index: 1,
                    text: author))
        }
        let publication = [chapter.siteName, date(chapter.capturedAt)]
            .compactMap { $0 }
            .joined(separator: " — ")
        content.append(
            boundary(
                tag: "p",
                cssClass: "publication",
                slot: slot,
                index: 2,
                text: publication))
        let imagesByBlockID = Dictionary(
            uniqueKeysWithValues: articleImages.map { ($0.owningBlockID, $0) })
        content.append(contentsOf: chapter.blocks.map {
            block($0, slot: slot, image: imagesByBlockID[$0.id])
        })
        let source = escapeAttribute(chapter.sourceURL.absoluteString)
        content.append(
            """
            <p class="source" id="echo-s\(slot)-b900000" data-echo-stable-slot="\(slot)" data-echo-block-index="900000" data-echo-narration="skip">Source: <a href="\(source)" data-echo-narration="skip">\(escapeText(chapter.sourceURL.absoluteString))</a></p>
            """)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml"
                  xml:lang="\(escapeAttribute(language))">
              <head>
                <title>\(escapeText(chapter.title))</title>
                <link rel="stylesheet" type="text/css" href="../styles.css"/>
              </head>
              <body>
            \(content.map { "    \($0)" }.joined(separator: "\n"))
              </body>
            </html>
            """
    }

    static func isXMLSafe(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value == 0x9 || $0.value == 0xA || $0.value == 0xD
                || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value)
                || (0x10000...0x10FFFF).contains($0.value)
        }
    }

    struct CoverAsset: Equatable, Sendable {
        let filename: String
        let mediaType: String
        let data: Data
    }

    private static func boundary(
        tag: String,
        cssClass: String? = nil,
        slot: Int,
        index: Int,
        text: String
    ) -> String {
        let classAttribute = cssClass.map { #" class="\#($0)""# } ?? ""
        return "<\(tag)\(classAttribute) id=\"echo-s\(slot)-b\(index)\" "
            + "data-echo-stable-slot=\"\(slot)\" data-echo-block-index=\"\(index)\">"
            + "\(escapeText(text))</\(tag)>"
    }

    private static func block(
        _ block: ArticleBlock,
        slot: Int,
        image: ArticleImageAssetDescriptor?
    ) -> String {
        let index = 1000 + block.stableOrdinal
        let text = escapeText(block.text ?? "")
        let attributes =
            "id=\"echo-s\(slot)-b\(index)\" data-echo-stable-slot=\"\(slot)\" "
            + "data-echo-block-index=\"\(index)\""
        switch block.kind {
        case .heading:
            return "<h2 \(attributes)>\(text)</h2>"
        case .paragraph:
            return "<p \(attributes)>\(text)</p>"
        case .listItem:
            return "<p class=\"list-item\" \(attributes)>\(text)</p>"
        case .quote:
            return "<blockquote \(attributes)>\(text)</blockquote>"
        case .code:
            let language =
                block.codeLanguage.map {
                    #" data-code-language="\#(escapeAttribute($0))""#
                } ?? ""
            return "<pre \(attributes)\(language)><code>\(text)</code></pre>"
        case .separator:
            return "<hr \(attributes)/>"
        case .image:
            guard let image else { return "<span \(attributes)></span>" }
            let href = "../" + String(image.archivePath.dropFirst("EPUB/".count))
            let alt = escapeAttribute(image.altText ?? "")
            let caption = image.caption.map {
                "<figcaption>\(escapeText($0))</figcaption>"
            } ?? ""
            return "<figure><img \(attributes) src=\"\(escapeAttribute(href))\" alt=\"\(alt)\"/>\(caption)</figure>"
        }
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
}
