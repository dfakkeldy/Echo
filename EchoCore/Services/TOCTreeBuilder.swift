import Foundation

/// A node in the reader's Table of Contents tree.
struct TOCNode: Identifiable {
    let id: String
    var title: String
    let blockID: String
    var children: [TOCNode]
}

/// Builds the Table of Contents tree from imported EPUB blocks.
///
/// Only real headings become nodes: junk headings (per `HeadingClassifier`)
/// are skipped, and spines without headings contribute nothing — titles are
/// never invented from filenames. Leading front-matter entries collapse into
/// a single expandable "Front Matter" group so cover/praise/preface pages
/// don't crowd the chapter list.
enum TOCTreeBuilder {

    static func build(from blocks: [EPubBlockRecord]) -> [TOCNode] {
        var rootNodes: [(node: TOCNode, isFrontMatter: Bool)] = []

        var partNodes: [TOCNode] = []
        var partID: String?
        var partTitle = ""
        var partBlockID = ""
        var partIsFrontMatter = false

        var chapterNodes: [TOCNode] = []
        var chapterID: String?
        var chapterTitle = ""
        var chapterBlockID = ""
        var chapterIsFrontMatter = false

        var currentSpineIndex = -1
        var spineHasHeading = false

        func flushChapter() {
            if let id = chapterID {
                let chapter = TOCNode(id: id, title: chapterTitle, blockID: chapterBlockID, children: chapterNodes)
                if partID != nil {
                    partNodes.append(chapter)
                } else {
                    rootNodes.append((chapter, chapterIsFrontMatter))
                }
            }
            chapterNodes = []
            chapterID = nil
            chapterIsFrontMatter = false
        }

        func flushPart() {
            flushChapter()
            if let id = partID {
                let part = TOCNode(id: id, title: partTitle, blockID: partBlockID, children: partNodes)
                rootNodes.append((part, partIsFrontMatter))
            }
            partNodes = []
            partID = nil
            partIsFrontMatter = false
        }

        for block in blocks {
            if block.spineIndex != currentSpineIndex {
                flushChapter()
                currentSpineIndex = block.spineIndex
                spineHasHeading = false
            }

            guard block.blockKind == EPubBlockRecord.Kind.heading.rawValue,
                  let text = block.text,
                  !text.isEmpty,
                  !HeadingClassifier.isJunk(text)
            else { continue }

            // Blocks imported before whitespace normalization landed may still
            // carry interior newlines until the book is re-imported.
            let title = text.collapsedWhitespace()

            if !spineHasHeading {
                // First real heading in this spine names the chapter (or part).
                spineHasHeading = true
                if title.lowercased().hasPrefix("part ") {
                    flushPart()
                    partID = block.id
                    partTitle = title
                    partBlockID = block.id
                    partIsFrontMatter = block.isFrontMatter
                } else {
                    chapterID = block.id
                    chapterTitle = title
                    chapterBlockID = block.id
                    chapterIsFrontMatter = block.isFrontMatter
                }
            } else {
                // Subsequent headings in the same spine are sections.
                let section = TOCNode(id: block.id, title: title, blockID: block.id, children: [])
                if chapterID != nil {
                    chapterNodes.append(section)
                } else if partID != nil {
                    partNodes.append(section)
                } else {
                    rootNodes.append((section, block.isFrontMatter))
                }
            }
        }
        flushPart()

        return groupingLeadingFrontMatter(rootNodes)
    }

    /// Collapses the leading run of front-matter nodes into one expandable
    /// "Front Matter" group. A single front-matter node stays inline — a
    /// group of one would just add a tap.
    private static func groupingLeadingFrontMatter(
        _ nodes: [(node: TOCNode, isFrontMatter: Bool)]
    ) -> [TOCNode] {
        let leadingCount = nodes.prefix(while: { $0.isFrontMatter }).count
        guard leadingCount >= 2 else {
            return nodes.map { $0.node }
        }
        let leading = nodes.prefix(leadingCount).map { $0.node }
        let rest = nodes.dropFirst(leadingCount).map { $0.node }
        let group = TOCNode(
            id: "front-matter-group",
            title: "Front Matter",
            blockID: leading[0].blockID,
            children: leading
        )
        return [group] + rest
    }
}
