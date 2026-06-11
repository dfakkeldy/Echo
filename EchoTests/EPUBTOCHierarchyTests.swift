import Testing
import Foundation
@testable import Echo

/// Tests for hierarchical TOC extraction.
///
/// The EPUB's NCX (`navPoint` nesting) or EPUB 3 nav (`ol` nesting) is the
/// publisher's authoritative chapter tree. The parser must preserve that
/// nesting — flattening it to per-file labels is what forced the reader to
/// re-derive structure from rendered headings, which breaks for books whose
/// section titles aren't marked up as `<h1>`–`<h6>` at all.
struct EPUBTOCHierarchyTests {

    // Modeled on The Pragmatic Programmer's real NCX: front matter with
    // nested preface sections, then chapters containing topics. Note the
    // chapter navPoint nests its children inside itself (no self-closing).
    private let ncx = """
    <?xml version="1.0" encoding="utf-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
    <docTitle><text>The Pragmatic Programmer</text></docTitle>
    <navMap>
      <navPoint id="d24e137" playOrder="1">
        <navLabel><text>Foreword</text></navLabel>
        <content src="f_0005.xhtml#d24e137"/>
      </navPoint>
      <navPoint id="d24e193" playOrder="2">
        <navLabel><text>Preface to the Second Edition</text></navLabel>
        <content src="f_0006.xhtml#d24e193"/>
        <navPoint id="d24e239" playOrder="3">
          <navLabel><text>How the Book Is Organized</text></navLabel>
          <content src="f_0007.xhtml#d24e239"/>
        </navPoint>
      </navPoint>
      <navPoint id="d24e636" playOrder="4">
        <navLabel><text>1. A Pragmatic Philosophy</text></navLabel>
        <content src="f_0017.xhtml#d24e636"/>
        <navPoint id="its_your_life" playOrder="5">
          <navLabel><text>Topic 1. It&#x27;s Your Life</text></navLabel>
          <content src="f_0018.xhtml#its_your_life"/>
        </navPoint>
        <navPoint id="no_broken_windows" playOrder="6">
          <navLabel><text>Topic 3. Software Entropy</text></navLabel>
          <content src="f_0020.xhtml#no_broken_windows"/>
        </navPoint>
      </navPoint>
    </navMap>
    </ncx>
    """

    @Test func ncxNavPointNestingBecomesEntryTree() throws {
        let parser = TOCParserDelegate()
        parser.parse(Data(ncx.utf8))
        let roots = parser.tocEntries

        #expect(roots.map(\.title) == [
            "Foreword",
            "Preface to the Second Edition",
            "1. A Pragmatic Philosophy",
        ])
        // #require, not subscripts after #expect: a failed #expect keeps
        // executing, so roots[1] on a short array would trap the whole suite.
        let preface = try #require(roots.dropFirst().first)
        let chapter = try #require(roots.last)
        #expect(preface.children.map(\.title) == ["How the Book Is Organized"])
        #expect(chapter.children.map(\.title) == [
            "Topic 1. It's Your Life",
            "Topic 3. Software Entropy",
        ])
    }

    @Test func ncxEntriesCarryHrefAndFragment() {
        let parser = TOCParserDelegate()
        parser.parse(Data(ncx.utf8))
        let chapter = parser.tocEntries.last

        #expect(chapter?.href == "f_0017.xhtml")
        #expect(chapter?.fragment == "d24e636")
        #expect(chapter?.children.last?.href == "f_0020.xhtml")
        #expect(chapter?.children.last?.fragment == "no_broken_windows")
    }

    @Test func ncxTreeDoesNotBreakFlatTOCMap() {
        let parser = TOCParserDelegate()
        parser.parse(Data(ncx.utf8))
        #expect(parser.tocMap["f_0017.xhtml"] == "1. A Pragmatic Philosophy")
        #expect(parser.tocMap["f_0020.xhtml"] == "Topic 3. Software Entropy")
    }

    @Test func epub3NavOlNestingBecomesEntryTree() {
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body>
          <nav epub:type="toc">
            <ol>
              <li><a href="ch01.xhtml#start">Chapter One</a>
                <ol>
                  <li><a href="ch01.xhtml#s1">Section 1.1</a></li>
                  <li><a href="ch01a.xhtml">Section 1.2</a></li>
                </ol>
              </li>
              <li><a href="ch02.xhtml">Chapter Two</a></li>
            </ol>
          </nav>
          <nav epub:type="landmarks">
            <ol><li><a epub:type="bodymatter" href="ch01.xhtml">Start</a></li></ol>
          </nav>
        </body>
        </html>
        """
        let parser = TOCParserDelegate()
        parser.parse(Data(nav.utf8))
        let roots = parser.tocEntries

        #expect(roots.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(roots.first?.fragment == "start")
        #expect(roots.first?.children.map(\.title) == ["Section 1.1", "Section 1.2"])
        #expect(roots.first?.children.last?.href == "ch01a.xhtml")
        // Landmarks anchors must not leak into the TOC tree.
        #expect(!roots.contains { $0.title == "Start" })
    }

    // MARK: - Anchor ID capture

    @Test func blockAnchorIDsCaptureElementIDs() {
        // The NCX points at fragments like #no_broken_windows (a table id) and
        // #d24e636 (an h1 id). Blocks must record the ids they contain so TOC
        // entries can be resolved to block positions at import.
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
          <h1 class="chapter-title" id="d24e636"><span>Chapter 1</span></h1>
          <table class="arr-recipe" id="no_broken_windows"><tr>
            <td><span class="topic-label">Topic 3</span></td><td>Software Entropy</td>
          </tr></table>
          <p id="d24e1065">While software development is immune…</p>
        </body>
        </html>
        """
        let result = parseXHTML(from: Data(xhtml.utf8))

        let heading = result.blocks.first { $0.kind == .heading }
        #expect(heading?.anchorIDs.contains("d24e636") == true)

        let topicBlock = result.blocks.first { $0.text?.contains("Topic 3") == true }
        #expect(topicBlock?.anchorIDs.contains("no_broken_windows") == true)

        let paragraph = result.blocks.first { $0.text?.hasPrefix("While software") == true }
        #expect(paragraph?.anchorIDs.contains("d24e1065") == true)
    }

    @Test func anchorIDsBeforeFirstTextFlowIntoNextBlock() {
        // An id on a wrapper that flushes empty (e.g. a div opened before any
        // text) must carry forward to the block that eventually emits.
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
          <div id="wrapper"><div><p>First real text.</p></div></div>
        </body>
        </html>
        """
        let result = parseXHTML(from: Data(xhtml.utf8))
        let paragraph = result.blocks.first { $0.text == "First real text." }
        #expect(paragraph?.anchorIDs.contains("wrapper") == true)
    }
}
