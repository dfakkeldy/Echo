import Testing
import Foundation
@testable import Echo

/// Tests for structural EPUB metadata parsing: spine `linear` flags, the
/// EPUB 2 `<guide>`, EPUB 3 nav landmarks, and TOC source selection. These
/// signals tell us where body matter starts so front matter (cover, praise
/// pages, printed TOC) is not promoted to chapters.
struct EPUBStructureParsingTests {

    private let opf = """
    <?xml version="1.0"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
      <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav scripted"/>
        <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch1" href="ch01.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine toc="ncx">
        <itemref idref="cover" linear="no"/>
        <itemref idref="ch1"/>
      </spine>
      <guide>
        <reference type="cover" title="Cover" href="cover.xhtml"/>
        <reference type="text" title="Start" href="ch01.xhtml"/>
      </guide>
    </package>
    """

    @Test func opfParsesSpineLinearAttribute() {
        let result = parseOPF(from: Data(opf.utf8))
        #expect(result.spine.count == 2)
        #expect(result.spine[0].linear == false)
        #expect(result.spine[1].linear == true)
    }

    @Test func opfParsesGuideReferences() {
        let result = parseOPF(from: Data(opf.utf8))
        #expect(result.guideReferences.contains { $0.type == "text" && $0.href == "ch01.xhtml" })
        #expect(result.guideReferences.contains { $0.type == "cover" && $0.href == "cover.xhtml" })
    }

    @Test func opfPrefersEpub3NavOverNCXForTOC() {
        // The nav item's properties list is space-separated ("nav scripted"),
        // and the EPUB 3 nav doc should win over the legacy NCX.
        let result = parseOPF(from: Data(opf.utf8))
        #expect(result.tocHref == "nav.xhtml")
    }

    @Test func navTocParsingIgnoresLandmarksAnchorsAndCapturesThem() {
        // Landmarks listed FIRST so their labels would win under the old
        // first-wins map insertion if scoping were missing.
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body>
          <nav epub:type="landmarks">
            <ol>
              <li><a epub:type="cover" href="cover.xhtml">Cover</a></li>
              <li><a epub:type="bodymatter" href="ch01.xhtml">Start Reading</a></li>
            </ol>
          </nav>
          <nav epub:type="toc">
            <ol>
              <li><a href="cover.xhtml">Cover Page</a></li>
              <li><a href="ch01.xhtml">Chapter 1: A Pragmatic Philosophy</a></li>
            </ol>
          </nav>
        </body>
        </html>
        """
        let parser = TOCParserDelegate()
        parser.parse(Data(nav.utf8))
        #expect(parser.tocMap["ch01.xhtml"] == "Chapter 1: A Pragmatic Philosophy")
        #expect(parser.tocMap["cover.xhtml"] == "Cover Page")
        #expect(parser.landmarks.contains { $0.type == "bodymatter" && $0.href == "ch01.xhtml" })
    }
}
