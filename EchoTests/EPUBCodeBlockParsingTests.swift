// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct EPUBCodeBlockParsingTests {

    private func blocks(_ xhtml: String) -> [TextBlockDescriptor] {
        parseXHTML(from: Data(xhtml.utf8)).blocks
    }

    @Test func preBecomesCodeBlockWithWhitespacePreserved() {
        let parsed = blocks("""
            <html><body>
            <p>Consider this function:</p>
            <pre><code class="language-python">def greet(name):
                print(f"hi {name}")

                return name</code></pre>
            <p>It greets people.</p>
            </body></html>
            """)
        #expect(parsed.count == 3)
        #expect(parsed[1].kind == .code)
        #expect(parsed[1].text == "def greet(name):\n    print(f\"hi {name}\")\n\n    return name")
        #expect(parsed[1].codeLanguage == "python")
        #expect(parsed[1].narrationCue == "Code listing.")
        // Neighbors are untouched prose.
        #expect(parsed[0].text == "Consider this function:")
        #expect(parsed[2].text == "It greets people.")
    }

    @Test func syntaxHighlightSpansInsidePreContributeCharactersOnly() {
        let parsed = blocks("""
            <html><body><pre><span class="kw">let</span> x = <span class="num">5</span></pre></body></html>
            """)
        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .code)
        #expect(parsed[0].text == "let x = 5")
    }

    @Test func inlineCodeOutsidePreStaysSpokenProse() {
        let parsed = blocks("""
            <html><body><p>Call <code>len()</code> on the list.</p></body></html>
            """)
        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .paragraph)
        #expect(parsed[0].text == "Call len() on the list.")
    }

    @Test func figureFigcaptionSuppliesTheCue() {
        let parsed = blocks("""
            <html><body>
            <figure>
            <pre><code>x = 1</code></pre>
            <figcaption>Listing 4-2. Assigning a variable</figcaption>
            </figure>
            </body></html>
            """)
        let code = parsed.first { $0.kind == .code }
        #expect(code?.narrationCue == "Listing 4-2. Assigning a variable")
        // figcaption text must NOT leak into prose blocks.
        #expect(!parsed.contains { $0.kind == .paragraph && $0.text?.contains("Listing 4-2") == true })
    }

    @Test func figcaptionBeforePreAlsoSuppliesTheCue() {
        let parsed = blocks("""
            <html><body>
            <figure>
            <figcaption>Listing 1-1. Hello</figcaption>
            <pre>print("hi")</pre>
            </figure>
            </body></html>
            """)
        #expect(parsed.first { $0.kind == .code }?.narrationCue == "Listing 1-1. Hello")
    }

    @Test func figcaptionStructuralMarkupPreservesWordBoundaries() {
        let parsed = blocks("""
            <html><body><figure>
            <pre>let value = 42</pre>
            <figcaption>Listing 1<br/>Assigning <strong>a</strong><div>variable</div></figcaption>
            </figure></body></html>
            """)

        #expect(
            parsed.first { $0.kind == .code }?.narrationCue
                == "Listing 1 Assigning a variable"
        )
    }

    @Test func nestedFigureCaptionsStayWithTheirOwnCodeBlocks() {
        let parsed = blocks("""
            <html><body>
            <figure>
            <pre>outer()</pre>
            <figure>
            <pre>inner()</pre>
            <figcaption>Inner listing</figcaption>
            </figure>
            <figcaption>Outer listing</figcaption>
            </figure>
            </body></html>
            """)
        let codeBlocks = parsed.filter { $0.kind == .code }
        #expect(codeBlocks.count == 2)
        #expect(codeBlocks[0].text == "outer()")
        #expect(codeBlocks[0].narrationCue == "Outer listing")
        #expect(codeBlocks[1].text == "inner()")
        #expect(codeBlocks[1].narrationCue == "Inner listing")
    }

    @Test func emptyPreIsDropped() {
        let parsed = blocks("<html><body><pre>   \n  \n</pre><p>After.</p></body></html>")
        #expect(!parsed.contains { $0.kind == .code })
        #expect(parsed.count == 1)
    }

    @Test func brInsidePreBecomesNewline() {
        let parsed = blocks("<html><body><pre>line one<br/>line two</pre></body></html>")
        #expect(parsed[0].text == "line one\nline two")
    }

    @Test func languageSniffVariants() {
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "language-Swift") == "swift")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "highlight lang-rb") == "rb")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "brush:python") == "python")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "brush:python;") == "python")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "brush: python;") == "python")
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: "pretty") == nil)
        #expect(XHTMLBlockDelegate.codeLanguage(fromClassAttribute: nil) == nil)
    }

    @Test func tablesStillFlattenAsToday() {
        let parsed = blocks("""
            <html><body><table><tr><td>Topic</td><td>Entropy</td></tr></table></body></html>
            """)
        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .paragraph)
        #expect(parsed[0].text == "Topic Entropy")
    }
}
