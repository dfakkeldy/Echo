import Testing
import Foundation
@testable import Echo

/// Tests for whitespace normalization during EPUB parsing.
///
/// Publisher XHTML is pretty-printed, so text nodes frequently contain interior
/// newlines and indentation, and `XMLParser` splits text at every entity
/// reference. Extracted text must collapse whitespace runs to single spaces
/// without injecting spaces inside entity-split words.
struct EPUBTextNormalizationTests {

    @Test func headingInteriorNewlineCollapsesToSingleSpaces() {
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>ch01</title></head>
        <body>
          <h2 class="chapterTitle">Chapter
              1 A Pragmatic Philosophy</h2>
          <p>This book is about you.</p>
        </body>
        </html>
        """
        let result = parseXHTML(from: Data(xhtml.utf8))
        let heading = result.blocks.first { $0.kind == .heading }
        #expect(heading?.text == "Chapter 1 A Pragmatic Philosophy")
    }

    @Test func entityReferencesDoNotSplitWords() {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body><p>Make no mistake, it&#8217;s your career at AT&amp;T.</p></body>
        </html>
        """
        let result = parseXHTML(from: Data(xhtml.utf8))
        let paragraph = result.blocks.first { $0.kind == .paragraph }
        #expect(paragraph?.text == "Make no mistake, it\u{2019}s your career at AT&T.")
    }

    @Test func paragraphInteriorNewlinesCollapse() {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body><p>What distinguishes
            Pragmatic Programmers?</p></body>
        </html>
        """
        let result = parseXHTML(from: Data(xhtml.utf8))
        let paragraph = result.blocks.first { $0.kind == .paragraph }
        #expect(paragraph?.text == "What distinguishes Pragmatic Programmers?")
    }

    @Test func documentTitleIsWhitespaceNormalized() {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>The Pragmatic
            Programmer</title></head>
        <body><p>Hello.</p></body>
        </html>
        """
        let result = parseXHTML(from: Data(xhtml.utf8))
        #expect(result.title == "The Pragmatic Programmer")
    }

    @Test func ncxNavLabelsAreWhitespaceNormalized() {
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="np1" playOrder="1">
              <navLabel><text>Chapter
                  1 A Pragmatic Philosophy</text></navLabel>
              <content src="ch01.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """
        let parser = TOCParserDelegate()
        parser.parse(Data(ncx.utf8))
        #expect(parser.tocMap["ch01.xhtml"] == "Chapter 1 A Pragmatic Philosophy")
    }

    @Test func epub3NavLabelsAreWhitespaceNormalized() {
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body>
          <nav epub:type="toc">
            <ol>
              <li><a href="ch01.xhtml">Chapter
                  1 A Pragmatic Philosophy</a></li>
            </ol>
          </nav>
        </body>
        </html>
        """
        let parser = TOCParserDelegate()
        parser.parse(Data(nav.utf8))
        #expect(parser.tocMap["ch01.xhtml"] == "Chapter 1 A Pragmatic Philosophy")
    }
}
